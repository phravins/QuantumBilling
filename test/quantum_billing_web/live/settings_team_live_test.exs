defmodule QuantumBillingWeb.SettingsLive.TeamTest do
  @moduledoc """
  The owner-only Team page, and the rules behind it.

  Registration is invite-only because everyone in a business shares its
  books — there is no per-user scoping on invoices or clients, by design. So
  membership is full access, and this page is the only place it is granted.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts
  alias QuantumBilling.Businesses

  setup :register_and_log_in_owner

  describe "the sidebar" do
    test "keeps the Settings sections open on the Team page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/team")

      assert has_element?(view, "#settings-sections-toggle[checked]")
    end
  end

  describe "inviting" do
    test "sends an invitation and lists it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/team")

      html =
        view
        |> form("#invite-form", %{
          "invitation" => %{"email" => "new@example.com", "role" => "staff"}
        })
        |> render_submit()

      assert html =~ "Invitation sent to new@example.com"
      assert html =~ "new@example.com"
      assert html =~ "Pending"
    end

    test "refuses someone already on the team", %{conn: conn, user: owner} do
      {:ok, view, _html} = live(conn, ~p"/settings/team")

      html =
        view
        |> form("#invite-form", %{"invitation" => %{"email" => owner.email, "role" => "staff"}})
        |> render_submit()

      assert html =~ "already on the team"
    end

    test "adds an existing account straight away, with no invitation", %{conn: conn} do
      other = user_fixture(%{email: "other@example.com"})
      {:ok, _} = Accounts.remove_member(Businesses.default!(), other)

      {:ok, view, _html} = live(conn, ~p"/settings/team")

      html =
        view
        |> form("#invite-form", %{
          "invitation" => %{"email" => "other@example.com", "role" => "staff"}
        })
        |> render_submit()

      assert html =~ "is now on the team"
      assert role(other) == "staff"
      assert Accounts.list_invitations(Businesses.default!()) == []
      assert has_element?(view, "#remove-member-#{other.id}")
    end

    test "says so when the email could not be sent, and lists nothing", %{conn: conn} do
      # A relay on a closed local port: refused at once, without the network.
      QuantumBilling.Settings.ensure_organization()

      QuantumBilling.Repo.update_all(QuantumBilling.Settings.Organization,
        set: [smtp_host: "127.0.0.1", smtp_port: 1, smtp_username: nil, smtp_password: nil]
      )

      {:ok, view, _html} = live(conn, ~p"/settings/team")

      html =
        view
        |> form("#invite-form", %{
          "invitation" => %{"email" => "new@example.com", "role" => "staff"}
        })
        |> render_submit()

      assert html =~ "could not be sent"
      refute html =~ "Invitation sent"
      assert Accounts.list_invitations(Businesses.default!()) == []
    end

    test "re-inviting replaces the pending invitation rather than adding a second" do
      owner = owner_fixture()

      _first = invitation_token_fixture("new@example.com", invited_by: owner)
      second = invitation_token_fixture("new@example.com", invited_by: owner)

      # One live token per mailbox: two would mean two accounts from one
      # decision.
      assert length(Accounts.list_invitations(Businesses.default!())) == 1
      assert Accounts.registration_open?(second)
    end

    test "withdrawing an invitation kills the link", %{conn: conn, user: owner} do
      token = invitation_token_fixture("new@example.com", invited_by: owner)
      assert Accounts.registration_open?(token)

      {:ok, view, _html} = live(conn, ~p"/settings/team")
      [invitation] = Accounts.list_invitations(Businesses.default!())

      html = render_click(view, "revoke", %{"id" => to_string(invitation.id)})

      assert html =~ "withdrawn"
      refute Accounts.registration_open?(token)
    end
  end

  describe "roles" do
    test "promoting and demoting", %{conn: conn} do
      staff = user_fixture(%{email: "staff@example.com"})

      {:ok, view, _html} = live(conn, ~p"/settings/team")

      html = render_click(view, "set_role", %{"id" => to_string(staff.id), "role" => "owner"})
      assert html =~ "is now owner"
      assert role(staff) == "owner"

      html = render_click(view, "set_role", %{"id" => to_string(staff.id), "role" => "staff"})
      assert html =~ "is now staff"
      assert role(staff) == "staff"
    end

    test "the last owner cannot be demoted", %{conn: conn, user: owner} do
      {:ok, view, _html} = live(conn, ~p"/settings/team")

      html = render_click(view, "set_role", %{"id" => to_string(owner.id), "role" => "staff"})

      # A business with no owner has nobody who can invite, administer
      # credentials or export the data, and no way back short of a console.
      assert html =~ "only owner"
      assert role(owner) == "owner"

      html = render_click(view, "remove", %{"id" => to_string(owner.id)})
      assert html =~ "only owner"
      assert role(owner) == "owner"
    end

    test "removing takes someone out of this business only", %{conn: conn} do
      staff = user_fixture(%{email: "staff@example.com"})

      {:ok, view, _html} = live(conn, ~p"/settings/team")

      view |> element("#remove-member-#{staff.id}") |> render_click()

      assert role(staff) == nil
      refute has_element?(view, "#remove-member-#{staff.id}")
      # The account itself stays.
      assert Accounts.get_user_by_email("staff@example.com")
    end

    test "an unknown role is refused" do
      staff = user_fixture()

      assert {:error, changeset} = Accounts.set_role(Businesses.default!(), staff, "superuser")
      assert {"is invalid", _} = changeset.errors[:role]
    end
  end

  describe "a role cannot be granted to yourself" do
    test "the profile form ignores a submitted role", %{conn: conn, user: owner} do
      staff = user_fixture(%{email: "staff@example.com"})

      {:ok, _updated} =
        Accounts.update_user_profile(staff, %{
          "full_name" => "Staff Person",
          "role" => "owner"
        })

      assert role(staff) == "staff"
      assert role(owner) == "owner"
      assert conn
    end
  end

  test "a staff account cannot reach this page" do
    conn = log_in_user(build_conn(), user_fixture())

    assert {:error, {:redirect, %{to: "/dashboard"}}} = live(conn, ~p"/settings/team")
  end
end
