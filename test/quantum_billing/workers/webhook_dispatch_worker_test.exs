defmodule QuantumBilling.Workers.WebhookDispatchWorkerTest do
  @moduledoc """
  The outgoing webhook delivery, which had no test at all.

  Requests are intercepted with `Req.Test` rather than by giving the worker a
  seam for tests to inject: the signature and the headers are the point of this
  worker, and they are only worth asserting on the bytes that would really have
  gone over the wire.
  """
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.Settings
  alias QuantumBilling.Webhooks
  alias QuantumBilling.Workers.WebhookDispatchWorker

  @secret "whsec_test_secret"

  setup do
    {:ok, _organization} =
      Settings.update_section(
        Settings.get_organization(),
        %{"webhook_url" => "https://hooks.example.test/incoming", "webhook_secret" => @secret},
        :integrations
      )

    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    on_exit(fn -> Req.default_options(previous) end)

    # Oban runs jobs inline here, in a process of its own, so the stub has to
    # be reachable from outside the test process.
    Req.Test.set_req_test_to_shared()

    :ok
  end

  # A blank credential means "I did not touch it" — the settings form is
  # write-only for secrets, so it always posts an empty box. Clearing one for
  # real is a direct write.
  defp clear_webhook_secret do
    Settings.get_organization()
    |> Ecto.Changeset.change(%{webhook_secret: nil})
    |> Repo.update!()
  end

  defp run(args), do: perform_job(WebhookDispatchWorker, args)

  defp perform_job(worker, args) do
    worker.perform(%Oban.Job{args: args, attempt: 1, max_attempts: 6})
  end

  describe "a successful delivery" do
    test "posts the event, signed, and reports ok" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:delivered, conn.method, conn.request_path, body, conn.req_headers})
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      assert :ok = run(%{"event" => "invoice.created", "payload" => %{"invoice_id" => 42}})

      assert_receive {:delivered, "POST", "/incoming", body, headers}

      decoded = Jason.decode!(body)
      assert decoded["event"] == "invoice.created"
      assert decoded["payload"] == %{"invoice_id" => 42}
      assert decoded["sent_at"]

      headers = Map.new(headers)
      assert headers["x-quantumbilling-event"] == "invoice.created"
      assert headers["content-type"] == "application/json"
      assert headers["x-quantumbilling-timestamp"]

      # Computed over the exact bytes sent. An endpoint that re-encodes the
      # JSON before checking is comparing against a different document, which
      # is why this asserts on `body` rather than on a re-encoding of it.
      assert headers["x-quantumbilling-signature"] == Webhooks.sign(body, @secret)
      assert Webhooks.valid_signature?(body, headers["x-quantumbilling-signature"], @secret)
    end

    test "sends no signature header when no secret is configured" do
      clear_webhook_secret()

      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, {:headers, conn.req_headers})
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert :ok = run(%{"event" => "invoice.paid", "payload" => %{}})

      assert_receive {:headers, headers}
      refute Map.has_key?(Map.new(headers), "x-quantumbilling-signature")
    end

    test "treats the whole 2xx range as delivered" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 202, "") end)

      assert :ok = run(%{"event" => "invoice.created", "payload" => %{}})
    end
  end

  describe "a delivery that fails" do
    test "retries a server error" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

      assert {:error, message} = run(%{"event" => "invoice.created", "payload" => %{}})
      assert message =~ "500"
    end

    test "retries a timeout and a rate limit, which are temporary" do
      for status <- [408, 429] do
        Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, status, "") end)

        assert {:error, message} = run(%{"event" => "invoice.created", "payload" => %{}})
        assert message =~ to_string(status)
      end
    end

    test "gives up on a client error, which repeating cannot fix" do
      for status <- [400, 401, 403, 404, 422] do
        Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, status, "") end)

        assert :discard = run(%{"event" => "invoice.created", "payload" => %{}})
      end
    end

    test "retries a transport failure" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, message} = run(%{"event" => "invoice.created", "payload" => %{}})
      assert message =~ "webhook delivery failed"
    end
  end

  describe "a job with nothing to deliver to" do
    test "is discarded when the endpoint has been removed since queueing" do
      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"webhook_url" => ""},
          :integrations
        )

      # No retry will conjure an endpoint that is not configured.
      assert :discard = run(%{"event" => "invoice.created", "payload" => %{}})
    end

    test "is discarded when the job carries no event" do
      assert :discard = run(%{"payload" => %{}})
    end
  end

  describe "the stored signing secret" do
    test "survives a settings save that posts the secret box empty" do
      # The box is write-only, so it renders empty on every load and posts
      # empty on every save. Treating that as "clear it" would wipe the
      # secret whenever anyone changed the webhook URL.
      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"webhook_url" => "https://hooks.example.test/moved", "webhook_secret" => ""},
          :integrations
        )

      assert Settings.get_organization().webhook_secret == @secret
    end
  end

  describe "Webhooks.dispatch/2" do
    test "queues a job when an endpoint is configured" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end)

      assert {:ok, %Oban.Job{} = job} =
               Webhooks.dispatch("invoice.created", %{"invoice_id" => 7})

      assert job.worker == "QuantumBilling.Workers.WebhookDispatchWorker"
      assert job.args["event"] == "invoice.created"
      assert job.queue == "webhooks"
    end

    test "is a no-op, not a failure, when none is" do
      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"webhook_url" => ""},
          :integrations
        )

      # Every caller would otherwise have to check the setting before
      # announcing anything.
      assert {:ok, :not_configured} = Webhooks.dispatch("invoice.created", %{})
    end
  end
end
