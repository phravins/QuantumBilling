defmodule QuantumBillingWeb.API.QuotationsTest do
  @moduledoc """
  `/api/v1/quotations`: list, fetch, create, email, accept and decline.
  """
  use QuantumBillingWeb.ConnCase, async: false

  import Ecto.Query
  import QuantumBilling.ApiFixtures

  alias QuantumBilling.Audit.AuditLog
  alias QuantumBilling.Quotations
  alias QuantumBilling.Quotations.Quotation
  alias QuantumBilling.QuotationsFixtures
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings

  @actor [via: "test"]

  setup do
    {:ok, _organization} =
      Settings.update_section(
        Settings.get_organization(),
        %{"company_name" => "ABC Solutions", "state" => "Maharashtra (27)"},
        :general
      )

    client = client_fixture()
    %{client: client}
  end

  defp quotation(client, over \\ %{}) do
    QuotationsFixtures.quotation_fixture(
      @actor,
      Map.merge(%{"client_id" => client.id, "client_email" => client.email}, over)
    )
  end

  defp expire!(quotation) do
    today = Quotations.today()

    quotation
    |> Ecto.Changeset.change(
      quotation_date: Date.add(today, -40),
      valid_until: Date.add(today, -1)
    )
    |> Repo.update!()
  end

  # Other mail (the key's security alert) may come first.
  defp quotation_email(%Quotation{number: number}) do
    assert_received {:email, %Swoosh.Email{subject: "Quotation " <> rest} = email}
    assert rest =~ number
    email
  end

  describe "GET /quotations" do
    test "lists with the effective status and filters by it", %{client: client} do
      {raw, _key} = api_key_fixture(["quotations:read"])
      open = quotation(client)
      expired = client |> quotation() |> expire!()

      all = raw |> api_conn() |> get(~p"/api/v1/quotations") |> json_response(200)

      statuses = Map.new(all["data"], &{&1["id"], &1["status"]})
      assert statuses[open.id] == "Draft"
      assert statuses[expired.id] == "Expired"

      only_expired =
        raw |> api_conn() |> get(~p"/api/v1/quotations?status=Expired") |> json_response(200)

      assert Enum.map(only_expired["data"], & &1["id"]) == [expired.id]
    end

    test "refuses an unknown status", %{client: _client} do
      {raw, _key} = api_key_fixture(["quotations:read"])
      conn = raw |> api_conn() |> get(~p"/api/v1/quotations?status=Paid")
      assert json_response(conn, 400)["error"]["fields"]["status"]
    end

    test "leaves the Bin out", %{client: client} do
      {raw, _key} = api_key_fixture(["quotations:read"])
      binned = quotation(client)
      {:ok, _} = Quotations.delete_quotation(@actor, binned)

      list = raw |> api_conn() |> get(~p"/api/v1/quotations") |> json_response(200)
      refute Enum.any?(list["data"], &(&1["id"] == binned.id))

      conn = raw |> api_conn() |> get(~p"/api/v1/quotations/#{binned.id}")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "GET /quotations/:id" do
    test "shows the items; the client link only to a key that may write", %{client: client} do
      quotation = quotation(client)
      {:ok, quotation} = Quotations.ensure_public_token(quotation)

      {reader, _key} = api_key_fixture(["quotations:read"])

      data =
        reader |> api_conn() |> get(~p"/api/v1/quotations/#{quotation.id}") |> json_response(200)

      assert [%{"description" => "Web Development Services"}] = data["data"]["items"]
      assert data["data"]["number"] == quotation.number
      refute Map.has_key?(data["data"], "public_url")

      {writer, _key} = api_key_fixture(["quotations:read", "quotations:write"])

      data =
        writer |> api_conn() |> get(~p"/api/v1/quotations/#{quotation.id}") |> json_response(200)

      assert data["data"]["public_url"] =~ quotation.public_token
    end
  end

  describe "POST /quotations" do
    test "creates a Draft with the business's validity period", %{client: client} do
      {:ok, _} =
        Settings.update_section(
          Settings.get_organization(),
          %{"quotation_validity_days" => "15"},
          :invoice
        )

      {raw, key} = api_key_fixture(["quotations:write"])

      conn =
        raw
        |> api_conn()
        |> api_post(~p"/api/v1/quotations", %{
          "client_id" => client.id,
          "place_of_supply" => "Maharashtra (27)",
          "items" => [%{"description" => "Audit", "rate" => 1_000_000, "tax_rate" => 18}]
        })

      data = json_response(conn, 201)["data"]
      assert data["status"] == "Draft"
      assert data["client"]["name"] == client.name
      assert data["valid_until"] == Date.to_iso8601(Date.add(Quotations.today(), 15))
      assert data["amounts"]["grand_total"] == 1_180_000

      assert Repo.exists?(
               from l in AuditLog,
                 where:
                   l.resource_type == "Quotation" and l.resource_id == ^to_string(data["id"]),
                 where: l.api_key_id == ^key.id
             )
    end

    test "refuses an unknown client and an invoice-only field", %{client: client} do
      {raw, _key} = api_key_fixture(["quotations:write"])
      item = [%{"description" => "Audit", "rate" => 100}]

      conn =
        raw
        |> api_conn()
        |> api_post(~p"/api/v1/quotations", %{"client_id" => -1, "items" => item})

      assert json_response(conn, 422)["error"]["fields"]["client_id"]

      conn =
        raw
        |> api_conn()
        |> api_post(~p"/api/v1/quotations", %{
          "client_id" => client.id,
          "due_date" => "2026-12-01",
          "items" => item
        })

      assert json_response(conn, 422)["error"]["fields"]["due_date"]
    end
  end

  describe "POST /quotations/:id/send" do
    test "emails the client, with the link, and marks it Sent", %{client: client} do
      {raw, _key} = api_key_fixture(["quotations:write"])
      quotation = quotation(client)

      conn = raw |> api_conn() |> api_post(~p"/api/v1/quotations/#{quotation.id}/send", %{})

      data = json_response(conn, 202)["data"]
      assert data["status"] == "Sent"
      assert data["public_url"]

      email = quotation_email(quotation)
      assert email.to == [{"", client.email}]
      assert email.text_body =~ data["public_url"]
      assert [%{filename: "Quotation-" <> _}] = email.attachments
    end

    test "takes another recipient, refuses a bad one and an expired quotation", %{client: client} do
      {raw, _key} = api_key_fixture(["quotations:write"])
      quotation = quotation(client)

      conn =
        raw
        |> api_conn()
        |> api_post(~p"/api/v1/quotations/#{quotation.id}/send", %{"to" => "buyer@acme.test"})

      assert json_response(conn, 202)
      assert quotation_email(quotation).to == [{"", "buyer@acme.test"}]

      conn =
        raw
        |> api_conn()
        |> api_post(~p"/api/v1/quotations/#{quotation.id}/send", %{"to" => "a@b.test, c@d.test"})

      assert json_response(conn, 422)["error"]["fields"]["to"]

      expired = client |> quotation() |> expire!()
      conn = raw |> api_conn() |> api_post(~p"/api/v1/quotations/#{expired.id}/send", %{})
      assert json_response(conn, 409)["error"]["code"] == "expired"
    end
  end

  describe "accept and decline" do
    test "answer an open quotation once", %{client: client} do
      {raw, _key} = api_key_fixture(["quotations:write"])
      quotation = quotation(client)

      conn = raw |> api_conn() |> api_post(~p"/api/v1/quotations/#{quotation.id}/accept", %{})
      assert json_response(conn, 200)["data"]["status"] == "Accepted"
      assert Repo.get!(Quotation, quotation.id).status == "Accepted"

      conn = raw |> api_conn() |> api_post(~p"/api/v1/quotations/#{quotation.id}/decline", %{})
      assert json_response(conn, 409)["error"]["code"] == "invalid_transition"
    end

    test "returns 409 when a quotation changes between fetch and acceptance", %{client: client} do
      {raw, _key} = api_key_fixture(["quotations:write"])
      quotation = quotation(client)
      handler_id = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler_id,
          [:quantum_billing, :repo, :query],
          fn _event, _measurements, metadata, {quotation, next_revision} ->
            query = metadata[:query] || ""

            if not Process.get(:quotation_revision_bumped, false) and
                 String.starts_with?(String.trim_leading(query), "SELECT") and
                 String.contains?(query, "quotations") and
                 not String.contains?(String.upcase(query), "FOR UPDATE") do
              Process.put(:quotation_revision_bumped, true)

              Repo.update!(
                Ecto.Changeset.change(quotation, revision: next_revision)
              )
            end
          end,
          {quotation, quotation.revision + 1}
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      conn =
        raw
        |> api_conn()
        |> api_post(~p"/api/v1/quotations/#{quotation.id}/accept", %{})

      assert json_response(conn, 409)["error"]["code"] == "stale_revision"
      current = Repo.get!(Quotation, quotation.id)
      assert current.status == "Draft"
      assert current.revision == quotation.revision + 1
    end

    test "an expired quotation cannot be accepted, and a body is refused", %{client: client} do
      {raw, _key} = api_key_fixture(["quotations:write"])
      expired = client |> quotation() |> expire!()

      conn = raw |> api_conn() |> api_post(~p"/api/v1/quotations/#{expired.id}/accept", %{})
      assert json_response(conn, 409)["error"]["code"] == "invalid_transition"

      open = quotation(client)

      conn =
        raw
        |> api_conn()
        |> api_post(~p"/api/v1/quotations/#{open.id}/decline", %{"status" => "Accepted"})

      assert json_response(conn, 422)
      assert Repo.get!(Quotation, open.id).status == "Draft"
    end
  end
end
