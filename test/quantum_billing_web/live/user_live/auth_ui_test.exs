defmodule QuantumBillingWeb.UserLive.AuthUITest do
  @moduledoc """
  Guards the custom centered auth design, which the generator's own tests
  don't cover — they only assert behaviour, not that our layout replaced the
  default app shell.
  """
  use QuantumBillingWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "registration page" do
    test "renders the centered sign-up design", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users/register")

      assert html =~ "Create an account"
      assert html =~ "Enter your details below to create your account"
      assert html =~ ~s(placeholder="Username")
      assert html =~ ~s(placeholder="name@example.com")
      assert html =~ ~s(placeholder="Confirm password")
      assert html =~ "Create Account"
      # the design's divider label is uppercased in CSS, so the markup is mixed case
      assert html =~ "Or continue with"
      # shadcn's 350px form column and type scale
      assert html =~ "sm:w-[350px]"
      assert html =~ "text-2xl font-semibold tracking-tight"
      assert html =~ "GitHub"
      assert html =~ "Terms of Service"
      assert html =~ "Privacy Policy"
    end

    test "shows QuantumBilling branding and no sidebar", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users/register")

      assert html =~ "QuantumBilling"
      # the tagline sits at the foot of every auth screen
      assert html =~ "GST invoicing, e-way bills and compliance — all in one place."
      # the app shell's sidebar links must not leak onto the auth screens
      refute html =~ ~s(href="/invoices")
      refute html =~ "Need Help?"
    end

    test "links across to the login page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users/register")

      assert html =~ ~s(href="/users/log-in")
      assert html =~ "Login"
    end
  end

  describe "login page" do
    test "renders the centered sign-in design", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/users/log-in")

      assert html =~ "Welcome back"
      assert html =~ ~s(placeholder="Password")
      assert html =~ "Sign In"
      assert html =~ "Or continue with"
      # the legal footnote belongs on both auth screens, not just sign-up
      assert html =~ "By clicking continue, you agree to our"
      assert html =~ "Terms of Service"
      assert html =~ "Privacy Policy"
      assert html =~ "QuantumBilling"
      assert html =~ ~s(href="/users/register")
      refute html =~ "Need Help?"
    end
  end

  describe "route gating" do
    test "signed-out visitors are redirected away from the app", %{conn: conn} do
      for path <- ["/", "/dashboard", "/invoices", "/clients", "/settings"] do
        assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, path)
      end
    end
  end

  describe "signed-in shell" do
    setup :register_and_log_in_user

    test "topbar shows the signed-in email and a working sign-out link", %{
      conn: conn,
      user: user
    } do
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ user.email
      assert html =~ ~s(href="/users/log-out")
      assert html =~ ~s(href="/users/settings")
      refute html =~ "Priya Sharma"
    end
  end
end
