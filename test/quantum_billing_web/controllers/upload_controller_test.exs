defmodule QuantumBillingWeb.UploadControllerTest do
  use QuantumBillingWeb.ConnCase, async: true

  alias QuantumBilling.Businesses
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings
  alias QuantumBilling.Uploads

  defp stored_file(_context) do
    File.mkdir_p!(Uploads.directory())

    name = "access-#{System.unique_integer([:positive])}.png"
    path = Path.join(Uploads.directory(), name)
    File.write!(path, <<0x89, "PNG\r\n", 0x1A, "\n", 0, 0, 0, 0>>)
    on_exit(fn -> File.rm(path) end)

    %{name: name}
  end

  defp use_as_logo(name) do
    {:ok, _} =
      Settings.update_section(
        Settings.get_organization(),
        %{"doc_logo_path" => "/uploads/#{name}"},
        :customization
      )
  end

  describe "signed out" do
    setup :stored_file

    test "a real file is forbidden, with a refresh to sign in", %{conn: conn, name: name} do
      use_as_logo(name)
      conn = get(conn, "/uploads/#{name}")

      html = html_response(conn, 403)
      assert html =~ "forbidden-illustration"
      assert html =~ ~s(content="10;url=/users/log-in")
      assert get_session(conn, :user_return_to) == "/uploads/#{name}"
    end

    test "a file that does not exist looks the same", %{conn: conn, name: name} do
      use_as_logo(name)

      real = conn |> get("/uploads/#{name}") |> html_response(403)
      missing = conn |> get("/uploads/no-such-file.png") |> html_response(403)

      assert real == missing
    end

    test "other file routes are forbidden too", %{conn: conn} do
      for path <- [
            ~p"/invoices/1/pdf",
            ~p"/invoices/1/pdf/download",
            ~p"/invoices/1/e-invoice.xml",
            ~p"/e-way-bills/1/print",
            ~p"/e-way-bills/export",
            ~p"/reports/export",
            ~p"/reports/gstr1/export",
            ~p"/settings/backup/download"
          ] do
        assert conn |> get(path) |> html_response(403) =~ "forbidden-illustration"
      end
    end
  end

  describe "signed in" do
    setup [:register_and_log_in_user, :stored_file]

    test "the business's own logo is served safely", %{conn: conn, name: name} do
      use_as_logo(name)
      conn = get(conn, "/uploads/#{name}")

      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "content-disposition") == ["attachment"]
      assert get_resp_header(conn, "cache-control") == ["private, max-age=300"]
    end

    test "a file that is not this business's logo is forbidden, with a way back", %{
      conn: conn,
      name: name
    } do
      html = conn |> get("/uploads/#{name}") |> html_response(403)

      assert html =~ ~s(content="10;url=/businesses")
    end

    test "another business's logo is forbidden", %{conn: conn, name: name} do
      owner = QuantumBilling.AccountsFixtures.owner_fixture()
      {:ok, other} = Businesses.create(owner, %{"name" => "Firm Two"})

      Repo.with_business(other, fn -> use_as_logo(name) end)

      assert conn |> get("/uploads/#{name}") |> response(403)
    end

    test "a path cannot climb out of the uploads directory", %{conn: conn} do
      assert conn |> get("/uploads/..%2F..%2Fapp.js") |> response(403)
      assert Uploads.locate("../secret.png") == :error
    end
  end
end
