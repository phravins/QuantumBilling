defmodule QuantumBilling.MailTest do
  use QuantumBilling.DataCase, async: true

  import Swoosh.TestAssertions

  alias QuantumBilling.Mail
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization

  describe "smtp_config/1" do
    test "falls back to the application mailer when no relay is configured" do
      assert Mail.smtp_config(%Organization{}) == []
      refute Mail.own_relay?(%Organization{})
    end

    test "verifies the relay's certificate and requires STARTTLS on 587" do
      config =
        Mail.smtp_config(%Organization{
          smtp_host: "smtp.example.com",
          smtp_port: 587,
          smtp_username: "postmaster",
          smtp_password: "secret"
        })

      assert config[:adapter] == Swoosh.Adapters.SMTP
      assert config[:relay] == "smtp.example.com"
      assert config[:port] == 587
      assert config[:ssl] == false
      # Required, not opportunistic: a downgrade would send the password in
      # the clear.
      assert config[:tls] == :always
      assert config[:auth] == :always
      assert config[:tls_options][:verify] == :verify_peer
      assert config[:tls_options][:server_name_indication] == ~c"smtp.example.com"
      assert config[:tls_options][:customize_hostname_check] != nil
    end

    test "connects with TLS immediately on 465" do
      config = Mail.smtp_config(%Organization{smtp_host: "smtp.example.com", smtp_port: 465})

      assert config[:ssl] == true
      assert config[:tls] == :never
      # Implicit TLS reads its options from the socket options, so the
      # verification settings have to be there too.
      assert config[:sockopts][:verify] == :verify_peer
    end

    test "does not authenticate when no username is configured" do
      config = Mail.smtp_config(%Organization{smtp_host: "relay.internal", smtp_port: 25})

      assert config[:auth] == :never
      refute Keyword.has_key?(config, :username)
    end

    test "trims a pasted host and treats blanks as unconfigured" do
      assert Mail.smtp_config(%Organization{smtp_host: "  "}) == []

      assert Mail.smtp_config(%Organization{smtp_host: " smtp.example.com "})[:relay] ==
               "smtp.example.com"
    end
  end

  describe "sender/2" do
    test "prefers the configured sender address, then the organisation's" do
      assert {"Books", "billing@acme.test"} =
               Mail.sender(
                 %Organization{
                   smtp_from_email: "billing@acme.test",
                   smtp_from_name: "Books",
                   email: "hello@acme.test"
                 },
                 nil
               )

      assert {"Acme", "hello@acme.test"} =
               Mail.sender(%Organization{email: "hello@acme.test", company_name: "Acme"}, nil)
    end

    test "falls back to the invoice's company name before the application's own" do
      assert {"Acme Exports", _} = Mail.sender(%Organization{}, "Acme Exports")
      assert {"QuantumBilling", _} = Mail.sender(%Organization{}, nil)
    end
  end

  describe "deliver/2" do
    test "sends through the application mailer when no relay is configured" do
      email =
        Swoosh.Email.new()
        |> Swoosh.Email.to("someone@example.com")
        |> Swoosh.Email.from({"QuantumBilling", "billing@example.com"})
        |> Swoosh.Email.subject("Hello")
        |> Swoosh.Email.text_body("Hi")

      assert {:ok, _metadata} = Mail.deliver(email, %Organization{})
      assert_email_sent(subject: "Hello")
    end
  end

  describe "send_test/1" do
    test "records the attempt in the delivery ledger" do
      assert {:ok, _metadata} = Mail.send_test("owner@example.com")

      assert [delivery] = Mail.list_recent_deliveries()
      assert delivery.to_email == "owner@example.com"
      assert delivery.kind == "test"
      assert delivery.status == "sent"
      assert delivery.attempts == 1
      assert delivery.delivered_at
    end
  end

  describe "the delivery ledger" do
    test "a failed attempt stays queued while Oban still intends to retry" do
      {:ok, delivery} =
        Mail.record_queued(%{to_email: "client@example.com", kind: "invoice", subject: "INV-1"})

      assert delivery.status == "queued"

      {:ok, delivery} = Mail.mark_failed(delivery, "relay refused", false)

      assert delivery.status == "queued"
      assert delivery.attempts == 1
      assert delivery.last_error == "relay refused"

      {:ok, delivery} = Mail.mark_failed(delivery, "relay refused again", true)

      assert delivery.status == "failed"
      assert delivery.attempts == 2
    end

    test "rejects a recipient that is not an address" do
      assert {:error, changeset} = Mail.record_queued(%{to_email: "not-an-address"})
      assert %{to_email: [_ | _]} = errors_on(changeset)
    end

    test "counts deliveries by status" do
      {:ok, sent} = Mail.record_queued(%{to_email: "a@example.com"})
      {:ok, _queued} = Mail.record_queued(%{to_email: "b@example.com"})
      {:ok, _} = Mail.mark_sent(sent)

      assert %{"sent" => 1, "queued" => 1} = Mail.delivery_counts()
    end

    test "announces changes on the mail topic" do
      Mail.subscribe()

      {:ok, delivery} = Mail.record_queued(%{to_email: "watch@example.com"})

      assert_receive {:email_delivery_changed, %{id: id}}
      assert id == delivery.id
    end
  end

  describe "error_message/1" do
    test "explains the failures a person has to fix" do
      assert Mail.error_message(:auth_failed) =~ "username or password"

      assert Mail.error_message({:network_failure, ~c"smtp.example.com", {:error, :nxdomain}}) =~
               "could not be resolved"

      assert Mail.error_message({:missing_requirement, ~c"smtp.example.com", :tls}) =~ "STARTTLS"

      assert Mail.error_message(
               {:network_failure, ~c"smtp.example.com",
                {:error, {:tls_alert, {:handshake_failure, ~c"bad certificate"}}}}
             ) =~ "certificate"
    end
  end

  describe "organisation credentials" do
    test "the SMTP password is encrypted in the database" do
      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"smtp_host" => "smtp.example.com", "smtp_password" => "plaintext-would-be-bad"},
          :smtp
        )

      # Read around Ecto, as a database dump or a replica would.
      %{rows: [[stored]]} =
        Repo.query!("SELECT smtp_password FROM organization_settings LIMIT 1", [])

      assert is_binary(stored)
      refute stored =~ "plaintext-would-be-bad"

      # And still usable through the schema, which is the point of encrypting
      # rather than hashing.
      assert Settings.get_organization().smtp_password == "plaintext-would-be-bad"
    end
  end
end
