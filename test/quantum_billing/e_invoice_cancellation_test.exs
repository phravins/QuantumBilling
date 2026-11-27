defmodule QuantumBilling.EInvoiceCancellationTest do
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.EInvoice.IRPClient
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice

  setup do
    {:ok, _} =
      QuantumBilling.Settings.update_section(
        QuantumBilling.Settings.get_organization(),
        %{
          "company_name" => "Acme Solutions Pvt Ltd",
          "gstin" => "27AABCU9603R1ZM",
          "state" => "Maharashtra",
          "city" => "Mumbai",
          "pincode" => "400001",
          "address" => "123 Business Park, Andheri East, Mumbai"
        },
        :general
      )

    :ok
  end

  defp create_test_invoice(overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          "invoice_date" => "2026-03-01",
          "due_date" => "2026-03-15",
          "payment_terms" => "Net 15 Days",
          "place_of_supply" => "Maharashtra (27)",
          "client_name" => "Test Buyer Pvt Ltd",
          "client_gstin" => "27AAACB2212R1ZU",
          "client_email" => "buyer@example.com",
          "client_billing_address" => "456 Market St, Mumbai",
          "items" => %{
            "0" => %{
              "description" => "Consulting Services",
              "hsn_sac" => "998311",
              "quantity" => "1",
              "unit" => "Nos",
              "rate" => "10000",
              "tax_rate" => "18",
              "position" => "0"
            }
          }
        },
        overrides
      )

    {:ok, invoice} = Invoices.create_invoice(attrs)
    invoice
  end

  describe "IRPClient.cancel_irn/4" do
    test "simulates cancellation in sandbox mode" do
      irn = "d3b07384d113edec49eaa6238ad5ff0000000000000000000000000000000000"
      assert {:ok, result} = IRPClient.cancel_irn(irn, "1", "Duplicate entry", force_sandbox: true)
      assert result.irn == irn
      assert %DateTime{} = result.cancel_date
    end
  end

  describe "Invoice.within_24_hour_irn_window?/1" do
    test "returns true when within 24 hours of ack_date" do
      recent = %Invoice{ack_date: DateTime.add(DateTime.utc_now(), -3600, :second)}
      assert Invoice.within_24_hour_irn_window?(recent)
    end

    test "returns false when ack_date is older than 24 hours" do
      expired = %Invoice{ack_date: DateTime.add(DateTime.utc_now(), -90_000, :second)}
      refute Invoice.within_24_hour_irn_window?(expired)
    end

    test "returns false when ack_date is nil" do
      no_ack = %Invoice{ack_date: nil}
      refute Invoice.within_24_hour_irn_window?(no_ack)
    end
  end

  describe "Invoices.cancel_e_invoice/4" do
    test "cancels e-invoice within 24-hour statutory window and saves metadata" do
      invoice = create_test_invoice()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Simulate an invoice with an active IRN registered 2 hours ago
      {:ok, registered} =
        invoice
        |> Ecto.Changeset.change(%{
          status: "E-Invoice Generated",
          irn: "9876543210abcdef9876543210abcdef9876543210abcdef9876543210abcdef",
          ack_number: "1234567890",
          ack_date: DateTime.add(now, -7200, :second),
          irn_mode: "demo"
        })
        |> QuantumBilling.Repo.update()

      assert {:ok, cancelled} =
               Invoices.cancel_e_invoice(registered, "2", "Clerical data entry mistake")

      assert cancelled.status == "Cancelled"
      assert cancelled.irn_cancellation_reason == "2"
      assert cancelled.irn_cancellation_remarks == "Clerical data entry mistake"
      assert %DateTime{} = cancelled.irn_cancelled_at
      assert Invoice.irn_cancelled?(cancelled)
    end

    test "refuses cancellation when statutory 24-hour window has expired" do
      invoice = create_test_invoice()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Registered 25 hours ago
      {:ok, registered} =
        invoice
        |> Ecto.Changeset.change(%{
          status: "E-Invoice Generated",
          irn: "9876543210abcdef9876543210abcdef9876543210abcdef9876543210abcdef",
          ack_number: "1234567890",
          ack_date: DateTime.add(now, -25 * 3600, :second),
          irn_mode: "demo"
        })
        |> QuantumBilling.Repo.update()

      assert {:error, :statutory_window_expired} =
               Invoices.cancel_e_invoice(registered, "1", "Duplicate")
    end

    test "refuses cancellation when invoice has no IRN" do
      invoice = create_test_invoice()
      assert {:error, :no_irn} = Invoices.cancel_e_invoice(invoice, "1", "Duplicate")
    end

    test "refuses cancellation when invoice is already cancelled" do
      invoice = create_test_invoice()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, registered} =
        invoice
        |> Ecto.Changeset.change(%{
          status: "Cancelled",
          irn: "9876543210abcdef9876543210abcdef9876543210abcdef9876543210abcdef",
          ack_number: "1234567890",
          ack_date: now
        })
        |> QuantumBilling.Repo.update()

      assert {:error, :already_cancelled} =
               Invoices.cancel_e_invoice(registered, "1", "Duplicate")
    end

    test "refuses cancellation when remarks exceed 100 characters" do
      invoice = create_test_invoice()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, registered} =
        invoice
        |> Ecto.Changeset.change(%{
          status: "E-Invoice Generated",
          irn: "9876543210abcdef9876543210abcdef9876543210abcdef9876543210abcdef",
          ack_number: "1234567890",
          ack_date: now,
          irn_mode: "demo"
        })
        |> QuantumBilling.Repo.update()

      long_remarks = String.duplicate("a", 101)

      assert {:error, :cancellation_remarks_too_long} =
               Invoices.cancel_e_invoice(registered, "1", long_remarks)
    end

    test "refuses cancellation when remarks are blank" do
      invoice = create_test_invoice()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, registered} =
        invoice
        |> Ecto.Changeset.change(%{
          status: "E-Invoice Generated",
          irn: "9876543210abcdef9876543210abcdef9876543210abcdef9876543210abcdef",
          ack_number: "1234567890",
          ack_date: now,
          irn_mode: "demo"
        })
        |> QuantumBilling.Repo.update()

      assert {:error, :blank_cancellation_remarks} =
               Invoices.cancel_e_invoice(registered, "1", "   ")
    end

    test "refuses cancellation when reason code is invalid" do
      invoice = create_test_invoice()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, registered} =
        invoice
        |> Ecto.Changeset.change(%{
          status: "E-Invoice Generated",
          irn: "9876543210abcdef9876543210abcdef9876543210abcdef9876543210abcdef",
          ack_number: "1234567890",
          ack_date: now,
          irn_mode: "demo"
        })
        |> QuantumBilling.Repo.update()

      assert {:error, :invalid_cancellation_reason} =
               Invoices.cancel_e_invoice(registered, "99", "Invalid reason")
    end

    test "refuses live IRN cancellation when live mode credentials are unavailable" do
      invoice = create_test_invoice()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, registered} =
        invoice
        |> Ecto.Changeset.change(%{
          status: "E-Invoice Generated",
          irn: "9876543210abcdef9876543210abcdef9876543210abcdef9876543210abcdef",
          ack_number: "1234567890",
          ack_date: now,
          irn_mode: "live"
        })
        |> QuantumBilling.Repo.update()

      # In test environment, live?() is false (sandbox mode)
      assert {:error, :live_cancellation_unavailable} =
               Invoices.cancel_e_invoice(registered, "1", "Duplicate entry")
    end
  end
end
