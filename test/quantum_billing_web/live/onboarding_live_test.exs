defmodule QuantumBillingWeb.OnboardingLiveTest do
  @moduledoc """
  The first-sign-in screens: who is sent there, the steps, and what each saves.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts
  alias QuantumBilling.Businesses
  alias QuantumBilling.Repo
  alias QuantumBilling.Settings

  describe "who is sent there" do
    setup :register_and_log_in_user

    test "a user who has not onboarded is sent there from a business page", %{
      conn: conn,
      user: user
    } do
      not_onboarded(user)

      assert {:error, {:redirect, %{to: "/onboarding"}}} = live(conn, ~p"/dashboard")
      assert {:error, {:redirect, %{to: "/onboarding"}}} = live(conn, ~p"/settings")
    end

    test "the onboarding page itself and the account pages do not loop", %{
      conn: conn,
      user: user
    } do
      not_onboarded(user)

      assert {:ok, _view, _html} = live(conn, ~p"/onboarding")
      assert {:ok, _view, _html} = live(conn, ~p"/users/settings")
    end

    test "someone who has onboarded goes straight in", %{conn: conn} do
      assert {:ok, _view, _html} = live(conn, ~p"/dashboard")
    end

    test "signed out, it asks for a sign-in" do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/onboarding")
    end
  end

  describe "signing in" do
    test "a user who has not onboarded lands on it", %{conn: conn} do
      user = user_fixture() |> set_password() |> not_onboarded()

      conn =
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })

      assert redirected_to(conn) == ~p"/onboarding"
    end
  end

  describe "the steps, as staff" do
    setup :register_and_log_in_user

    setup %{user: user} do
      %{user: not_onboarded(user)}
    end

    test "a focus screen with a progress bar and no app sidebar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/onboarding")

      assert has_element?(view, "#focus-shell")
      assert has_element?(view, "#focus-progress")
      refute has_element?(view, "#app-sidebar")
      assert has_element?(view, "#onboarding-step-1")
    end

    test "walks through to the end and is not shown again", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/onboarding")

      view |> element("#onboarding-next") |> render_click()
      assert has_element?(view, "#onboarding-profile-form")
      assert view |> element("#onboarding-email") |> render() =~ user.email

      # A name is required.
      view
      |> form("#onboarding-profile-form", profile: %{full_name: "  "})
      |> render_submit()

      assert has_element?(view, "#onboarding-profile-form")
      assert render(view) =~ "tell us what to call you"

      view
      |> form("#onboarding-profile-form",
        profile: %{
          full_name: "Priya Sharma",
          designation: "Accounts manager",
          phone: "+91 98765 43210",
          bio: "Keeps the books."
        }
      )
      |> render_submit()

      # Staff see the organisation, not a form for it.
      assert has_element?(view, "#onboarding-step-3")
      assert has_element?(view, "#onboarding-org-readonly")
      refute has_element?(view, "#onboarding-org-form")

      view |> element("#onboarding-next") |> render_click()
      assert has_element?(view, "#onboarding-done")

      view |> element("#onboarding-finish") |> render_click()
      assert_redirect(view, ~p"/")

      saved = Accounts.get_user!(user.id)
      assert saved.full_name == "Priya Sharma"
      assert saved.bio == "Keeps the books."
      assert saved.onboarded_at

      assert {:ok, _view, _html} = live(conn, ~p"/dashboard")
    end

    test "Back returns to the previous step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/onboarding")

      view |> element("#onboarding-next") |> render_click()
      view |> element("#onboarding-back") |> render_click()

      assert has_element?(view, "#onboarding-step-1")
    end

    test "a bio over 500 characters is refused", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/onboarding")
      view |> element("#onboarding-next") |> render_click()

      view
      |> form("#onboarding-profile-form",
        profile: %{full_name: "Priya", bio: String.duplicate("a", 501)}
      )
      |> render_submit()

      assert has_element?(view, "#onboarding-step-2")
    end

    test "Skip for now ends it from any step", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/onboarding")

      view |> element("#onboarding-skip") |> render_click()
      assert_redirect(view, ~p"/")

      assert Accounts.get_user!(user.id).onboarded_at
    end

    test "a forged organisation save from staff changes nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/onboarding")
      before = Settings.get_organization().company_name

      render_hook(view, "save_org", %{"organization" => %{"company_name" => "Forged Ltd"}})

      assert Settings.get_organization().company_name == before
      assert Businesses.default!().name != "Forged Ltd"
    end
  end

  describe "the organisation step, as an owner" do
    setup :register_and_log_in_owner

    setup %{user: user} do
      %{user: not_onboarded(user)}
    end

    test "saves the company's details and gives the business the same name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/onboarding")

      view |> element("#onboarding-next") |> render_click()

      view
      |> form("#onboarding-profile-form", profile: %{full_name: "Asha Rao"})
      |> render_submit()

      assert has_element?(view, "#onboarding-org-form")

      # An invalid GSTIN is caught by the General settings' own validation.
      view
      |> form("#onboarding-org-form",
        organization: %{company_name: "Rao Exports", gstin: "NOPE"}
      )
      |> render_submit()

      assert has_element?(view, "#onboarding-step-3")

      view
      |> form("#onboarding-org-form",
        organization: %{
          company_name: "Rao Exports",
          email: "accounts@rao.example",
          gstin: "",
          state: ""
        }
      )
      |> render_submit()

      assert has_element?(view, "#onboarding-done")

      organization = Repo.with_business(Businesses.default!(), &Settings.get_organization/0)
      assert organization.company_name == "Rao Exports"
      assert organization.email == "accounts@rao.example"
      assert Businesses.default!().name == "Rao Exports"
    end
  end
end
