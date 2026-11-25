defmodule QuantumBilling.Workers.PaymentLinkCancelWorkerTest do
  @moduledoc """
  Cancelling an invoice cancels its Razorpay payment link (Oban runs inline in
  test). A link Razorpay will not cancel is raised with the owner.
  """
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.Audit.AuditLog
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Notifications.Notification
  alias QuantumBilling.Workers.PaymentLinkCancelWorker

  defp invoice(attrs) do
    Repo.insert!(
      struct!(
        %Invoice{
          invoice_number: "INV-8101",
          invoice_date: ~D[2026-03-01],
          place_of_supply: "Maharashtra",
          company_state: "Maharashtra",
          client_name: "Zeta Corp",
          grand_total: 500_000,
          status: "Draft"
        },
        attrs
      )
    )
  end

  defp with_razorpay_stub(fun) do
    System.put_env("RAZORPAY_KEY_ID", "rzp_test_key")
    System.put_env("RAZORPAY_KEY_SECRET", "rzp_test_secret")
    previous = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      System.delete_env("RAZORPAY_KEY_ID")
      System.delete_env("RAZORPAY_KEY_SECRET")
      Req.default_options(previous)
    end)

    Req.Test.stub(__MODULE__, fun)
  end

  defp perform_job(invoice_id) do
    PaymentLinkCancelWorker.perform(%Oban.Job{
      args: %{"invoice_id" => invoice_id},
      attempt: 1,
      max_attempts: 5
    })
  end

  test "cancelling the invoice cancels its link, keeping the id to match late payments" do
    test_pid = self()

    with_razorpay_stub(fn conn ->
      send(test_pid, {:cancelled, conn.request_path})
      Req.Test.json(conn, %{"id" => "plink_live1", "status" => "cancelled"})
    end)

    invoice =
      invoice(%{
        razorpay_payment_link_id: "plink_live1",
        razorpay_payment_url: "https://rzp.io/i/live1"
      })

    assert {:ok, _cancelled} = Invoices.cancel_invoice(invoice, "Duplicate order")

    assert_receive {:cancelled, "/v1/payment_links/plink_live1/cancel"}

    assert %Invoice{
             status: "Cancelled",
             razorpay_payment_link_id: "plink_live1",
             razorpay_payment_url: nil
           } = Repo.get(Invoice, invoice.id)

    assert Repo.exists?(
             from l in AuditLog,
               where:
                 l.action == "payment_link_cancelled" and
                   l.resource_id == ^to_string(invoice.id)
           )
  end

  test "an invoice without a link queues nothing" do
    with_razorpay_stub(fn _conn -> flunk("no request expected") end)
    invoice = invoice(%{invoice_number: "INV-8102"})

    assert {:ok, %Invoice{status: "Cancelled"}} = Invoices.cancel_invoice(invoice, "x")
  end

  test "a link Razorpay refuses to cancel is raised with the owner" do
    with_razorpay_stub(fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"error" => %{"description" => "Payment link is already paid"}})
    end)

    invoice =
      invoice(%{
        invoice_number: "INV-8103",
        status: "Cancelled",
        razorpay_payment_link_id: "plink_paid",
        razorpay_payment_url: "https://rzp.io/i/paid"
      })

    assert {:discard, "Payment link is already paid"} =
             perform_job(invoice.id)

    assert %Notification{severity: "warning", title: title} =
             Repo.get_by(Notification, dedupe_key: "payment_link_cancel:#{invoice.id}")

    assert title =~ "INV-8103"
    assert Repo.get(Invoice, invoice.id).razorpay_payment_url == "https://rzp.io/i/paid"
  end

  test "an invoice that is not cancelled is left alone" do
    with_razorpay_stub(fn _conn -> flunk("no request expected") end)
    invoice = invoice(%{invoice_number: "INV-8104", razorpay_payment_link_id: "plink_open"})

    assert :discard = perform_job(invoice.id)
  end
end
