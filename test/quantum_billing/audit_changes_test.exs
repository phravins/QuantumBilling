defmodule QuantumBilling.AuditChangesTest do
  @moduledoc """
  What an edit changed, as the audit log stores it: only the fields that
  moved, secrets as "changed" without their value, and bulky fields summed up.
  """
  use QuantumBilling.DataCase, async: true

  alias QuantumBilling.Audit
  alias QuantumBilling.Clients
  alias QuantumBilling.Clients.Client
  alias QuantumBilling.Settings
  alias QuantumBilling.Templates
  alias QuantumBillingWeb.InvoiceDoc.Catalog
  alias QuantumBillingWeb.InvoiceDoc.Layout

  import QuantumBilling.ApiFixtures, only: [client_fixture: 1]

  defp entries(action), do: Enum.filter(Audit.list_audit_logs(), &(&1.action == action))

  describe "changes/2" do
    test "lists only the fields that moved, from and to" do
      changeset =
        Ecto.Changeset.change(%Client{name: "Acme", email: "a@acme.in"}, name: "Acme Ltd")

      assert Audit.changes(changeset) == %{"name" => %{"from" => "Acme", "to" => "Acme Ltd"}}
    end

    test "a value set to what it already was is not a change" do
      changeset =
        %Client{name: "Acme"}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.force_change(:name, "Acme")

      assert Audit.changes(changeset) == %{}
    end

    test "summarised and skipped fields" do
      changeset =
        Ecto.Changeset.change(%Client{name: "A", email: "a@x.in"}, name: "B", email: "b@x.in")

      assert Audit.changes(changeset, summarize: [:name], skip: [:email]) ==
               %{"name" => %{"changed" => true}}
    end

    test "masks sensitive fields like bank_account_number" do
      org = %Settings.Organization{bank_account_number: "1234567890"}
      changeset = Ecto.Changeset.change(org, bank_account_number: "9876543210")

      assert Audit.changes(changeset) == %{
               "bank_account_number" => %{"from" => "••••7890", "to" => "••••3210"}
             }
    end
  end

  describe "edits through the contexts" do
    test "a client edit records what changed; a save with no change records nothing" do
      client = client_fixture(%{"name" => "Gamma Traders"})

      {:ok, client} = Clients.update_client(client, %{"phone" => "9123456780"})

      assert [log] = entries("client_updated")
      assert log.details["label"] == "Gamma Traders"

      assert log.details["changes"] == %{
               "phone" => %{"from" => "9876543210", "to" => "9123456780"}
             }

      {:ok, _same} = Clients.update_client(client, %{"phone" => "9123456780"})
      assert [_still_one] = entries("client_updated")
    end

    test "a secret is recorded as changed, never with its value" do
      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"smtp_host" => "smtp.example.com", "smtp_password" => "hunter2-in-the-log"},
          :smtp
        )

      assert [log] = entries("settings_updated")
      assert log.resource_id == "smtp"
      assert log.details["changes"]["smtp_password"] == %{"redacted" => true}
      assert log.details["changes"]["smtp_host"] == %{"from" => nil, "to" => "smtp.example.com"}
      refute Jason.encode!(log.details) =~ "hunter2-in-the-log"
    end

    test "the template designer's saves in one sitting are one entry" do
      {:ok, template} =
        Templates.create_template(%{
          "name" => "Studio",
          "layout_xml" => Layout.to_xml(Catalog.classic())
        })

      {:ok, template} = Templates.update_template(template, %{"accent" => "#112233"})
      {:ok, template} = Templates.update_template(template, %{"accent" => "#445566"})
      {:ok, _template} = Templates.update_template(template, %{"name" => "Studio Two"})

      assert [log] = entries("invoice_template_updated")
      assert log.details["edits"] == 3
      assert log.details["changes"]["accent"] == %{"from" => "#18181b", "to" => "#445566"}
      assert log.details["changes"]["name"] == %{"from" => "Studio", "to" => "Studio Two"}
    end

    test "a field put back where it started drops out of the merged entry" do
      {:ok, template} =
        Templates.create_template(%{
          "name" => "Studio",
          "layout_xml" => Layout.to_xml(Catalog.classic())
        })

      {:ok, template} = Templates.update_template(template, %{"accent" => "#112233"})
      {:ok, _template} = Templates.update_template(template, %{"accent" => "#18181b"})

      assert [log] = entries("invoice_template_updated")
      refute Map.has_key?(log.details["changes"] || %{}, "accent")
    end
  end
end
