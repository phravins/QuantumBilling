defmodule QuantumBilling.ErrorMessagesTest do
  @moduledoc """
  Every `{:error, reason}` a page shows goes through `ErrorMessages.text/1`,
  so a user reads a sentence and never an Elixir term.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Ecto.Changeset

  alias QuantumBilling.Clients.Client
  alias QuantumBilling.ErrorMessages
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Invoices.InvoiceItem

  @generic "Something went wrong. Please try again."

  describe "text/1" do
    test "a changeset gives its first error, with the field named" do
      changeset =
        %Client{}
        |> change()
        |> add_error(:billing_pin, "can't be blank", validation: :required)

      assert ErrorMessages.text(changeset) == "Billing pin can't be blank"
    end

    test "fills in the numbers a validation message refers to" do
      changeset =
        {%{}, %{name: :string}}
        |> cast(%{name: String.duplicate("a", 20)}, [:name])
        |> validate_length(:name, max: 10)

      assert ErrorMessages.text(changeset) =~ "10"
      refute ErrorMessages.text(changeset) =~ "%{count}"
    end

    test "finds an error on a nested changeset" do
      item = %InvoiceItem{} |> change() |> add_error(:rate, "must be positive")
      invoice = %Invoice{items: []} |> change() |> put_assoc(:items, [item])

      assert ErrorMessages.text(invoice) == "Rate must be positive"
    end

    test "a changeset with no errors still says something" do
      assert ErrorMessages.text(change(%Client{})) == "The change could not be saved."
    end

    test "known reasons have a fixed sentence" do
      assert ErrorMessages.text(:not_found) == "That record no longer exists."
      assert ErrorMessages.text(:in_use) =~ "still in use"
      assert ErrorMessages.text(:timeout) =~ "did not answer in time"
      assert ErrorMessages.text(:no_renderer) =~ "PDF export is not available"
    end

    test "a sentence is passed through" do
      assert ErrorMessages.text("GSTIN is not active on the portal.") ==
               "GSTIN is not active on the portal."
    end

    test "mail and portal failures use their own wording" do
      assert ErrorMessages.text({:delivery_failed, "Mailbox full."}) == "Mailbox full."
      assert ErrorMessages.text(:portal_unavailable) =~ "e-way bill portal is not responding"

      assert ErrorMessages.text({:network_failure, ~c"smtp.example.com", {:error, :timeout}}) =~
               "Timed out connecting to smtp.example.com"
    end

    test "anything else is a generic sentence, and the reason goes to the log" do
      log =
        capture_log(fn ->
          assert ErrorMessages.text({:weird, %{deep: [1, 2, 3]}}) == @generic
        end)

      assert log =~ ":weird"
    end

    test "an exception is a generic sentence, and is logged" do
      log =
        capture_log(fn ->
          assert ErrorMessages.text(%RuntimeError{message: "boom"}) == @generic
        end)

      assert log =~ "boom"
    end
  end

  describe "first_message/1" do
    test "the message alone, or nil" do
      changeset = %Client{} |> change() |> add_error(:gstin, "is not a valid GSTIN")

      assert ErrorMessages.first_message(changeset) == "is not a valid GSTIN"
      assert ErrorMessages.first_message(change(%Client{})) == nil
    end
  end
end
