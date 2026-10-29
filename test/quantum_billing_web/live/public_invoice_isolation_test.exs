defmodule QuantumBillingWeb.PublicInvoiceLiveIsolationTest do
  @moduledoc """
  What the unauthenticated payment page is allowed to know about.

  It is the one LiveView in the application that a stranger holding a link can
  open, so it must hear about its own invoice and nothing else, stop offering
  payment the moment that invoice is binned, and never show a visitor the
  internals of a failed payment.
  """
  use QuantumBillingWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Repo

  defp invoice(attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Invoice{
          invoice_number: "INV-#{System.unique_integer([:positive])}",
          invoice_date: ~D[2026-03-01],
          place_of_supply: "Maharashtra",
          company_state: "Maharashtra",
          client_name: "Zeta Logistics",
          public_token: Invoice.generate_public_token(),
          taxable_value: 10_000,
          cgst_amount: 900,
          sgst_amount: 900,
          grand_total: 11_800
        },
        attrs
      )
    )
  end

  defp subscribers(topic) do
    QuantumBilling.PubSub |> Registry.lookup(topic) |> Enum.map(fn {pid, _} -> pid end)
  end

  describe "what the page subscribes to" do
    test "its own invoice, and not the business's whole invoice stream", %{conn: conn} do
      mine = invoice()

      {:ok, view, _html} = live(conn, ~p"/pay/#{mine.public_token}")

      # The global topic carries every invoice change in the business. An
      # unauthenticated process has no business holding any of them, even
      # briefly, even to throw them away.
      refute view.pid in subscribers("invoices")
      assert view.pid in subscribers("invoice:#{mine.id}")
    end

    test "a change to another customer's invoice never reaches it", %{conn: conn} do
      mine = invoice(%{client_name: "Zeta Logistics"})
      theirs = invoice(%{client_name: "Someone Else Entirely"})

      {:ok, view, _html} = live(conn, ~p"/pay/#{mine.public_token}")

      Invoices.broadcast_change(%{theirs | client_name: "Someone Else Entirely"})

      html = render(view)
      assert html =~ "Zeta Logistics"
      refute html =~ "Someone Else Entirely"
    end

    test "a change to its own invoice still updates it live", %{conn: conn} do
      mine = invoice(%{status: "Draft"})

      {:ok, view, _html} = live(conn, ~p"/pay/#{mine.public_token}")

      paid =
        mine
        |> Ecto.Changeset.change(status: "Paid", razorpay_payment_id: "pay_live_1")
        |> Repo.update!()

      Invoices.broadcast_change(paid)

      assert render(view) =~ "pay_live_1"
    end

    test "renders what the database says, not what the message says", %{conn: conn} do
      mine = invoice(%{client_name: "Zeta Logistics"})

      {:ok, view, _html} = live(conn, ~p"/pay/#{mine.public_token}")

      # A broadcast is a signal to re-read. Whatever a message carries — and a
      # message missing its line items used to crash this page — is never
      # what ends up on an unauthenticated screen.
      Invoices.broadcast_change(%{mine | client_name: "Injected Through PubSub"})

      html = render(view)
      assert html =~ "Zeta Logistics"
      refute html =~ "Injected Through PubSub"
    end
  end

  describe "an invoice binned while the page is open" do
    test "stops being offered", %{conn: conn} do
      mine = invoice()

      {:ok, view, _html} = live(conn, ~p"/pay/#{mine.public_token}")

      # A fresh visit to this link already says it is gone. An open page used
      # to go on showing the invoice, and offering to take payment for it.
      {:ok, _binned} = Invoices.delete_invoice(mine)

      assert_redirect(view, "/")
    end

    test "cannot be paid by a click made after it was binned", %{conn: conn} do
      mine = invoice()

      {:ok, view, _html} = live(conn, ~p"/pay/#{mine.public_token}")

      # Binned behind the page's back, without a broadcast — the click must
      # check for itself rather than trust what was loaded.
      Repo.update!(Invoice.bin_changeset(mine))

      render_click(view, "pay_now")
      assert_redirect(view, "/")
    end
  end

  describe "a payment that cannot be started" do
    setup do
      previous = Application.get_env(:quantum_billing, :razorpay_sandbox)
      Application.put_env(:quantum_billing, :razorpay_sandbox, false)
      on_exit(fn -> Application.put_env(:quantum_billing, :razorpay_sandbox, previous) end)
    end

    test "tells the customer plainly, and keeps the reason for the business", %{conn: conn} do
      mine = invoice()

      {:ok, view, _html} = live(conn, ~p"/pay/#{mine.public_token}")

      log =
        capture_log(fn ->
          html = render_click(view, "pay_now")

          # Shown inline: this page has no layout, so a flash was never
          # rendered and a failed payment looked like a dead button.
          assert has_element?(view, "#payment-error", "Online payment is not available right now")

          # This used to flash `inspect(reason)` to an unauthenticated
          # visitor: a gateway error describing how payments are configured,
          # or a changeset carrying the invoice's own fields.
          refute html =~ "not configured"
          refute html =~ "Razorpay"
          refute html =~ "%{"
          refute html =~ "#Ecto"
        end)

      assert log =~ "payment link failed for invoice #{mine.id}"
    end
  end
end
