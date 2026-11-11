defmodule QuantumBillingWeb.ConfirmDialogTest do
  @moduledoc """
  `data-confirm` is answered in the root layout's `#confirm-dialog`, not the
  browser's `window.confirm` (see `assets/js/confirm_dialog.js`). The dialog
  has to be on every page, outside the LiveView container.
  """
  use QuantumBillingWeb.ConnCase, async: true

  defp dialog(html) do
    html |> LazyHTML.from_document() |> LazyHTML.query("dialog#confirm-dialog")
  end

  test "a signed-out page carries the dialog", %{conn: conn} do
    html = conn |> get(~p"/users/log-in") |> html_response(200)

    assert html |> dialog() |> Enum.count() == 1
  end

  describe "signed in" do
    setup :register_and_log_in_owner

    test "the dialog sits outside the LiveView, with Cancel and Confirm", %{conn: conn} do
      html = conn |> get(~p"/settings/team") |> html_response(200)
      document = LazyHTML.from_document(html)

      assert html |> dialog() |> Enum.count() == 1
      assert LazyHTML.query(document, "[data-phx-main] #confirm-dialog") |> Enum.count() == 0

      assert LazyHTML.query(document, "#confirm-dialog #confirm-dialog-cancel") |> Enum.count() ==
               1

      assert LazyHTML.query(document, "#confirm-dialog #confirm-dialog-ok") |> Enum.count() == 1
    end

    test "role changes ask in the neutral tone", %{conn: conn} do
      _staff = QuantumBilling.AccountsFixtures.user_fixture(%{email: "staff@example.com"})

      html = conn |> get(~p"/settings/team") |> html_response(200)
      buttons = html |> LazyHTML.from_document() |> LazyHTML.query(~s|[data-confirm^="Make "]|)

      assert Enum.count(buttons) > 0

      for button <- buttons do
        assert LazyHTML.attribute(button, "data-confirm-tone") == ["neutral"]
      end
    end
  end
end
