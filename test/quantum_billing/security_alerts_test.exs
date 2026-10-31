defmodule QuantumBilling.SecurityAlertsTest do
  @moduledoc "Who is told what, when something security-relevant happens."
  use QuantumBilling.DataCase, async: true

  import QuantumBilling.AccountsFixtures
  import Swoosh.TestAssertions

  alias QuantumBilling.{Businesses, SecurityAlerts}
  alias QuantumBilling.SecurityAlerts.SignIn

  # Account fixtures send their own confirmation mail; drop it so the
  # assertions below see only alerts.
  defp flush_emails do
    receive do
      {:email, _email} -> flush_emails()
    after
      0 -> :ok
    end
  end

  defp subject(text), do: "[QuantumBilling security] " <> text

  describe "sign-ins" do
    test "the first sign-in and later ones from known addresses are quiet" do
      user = user_fixture()
      flush_emails()

      SecurityAlerts.signed_in(user, "203.0.113.5", "Firefox", :browser)
      SecurityAlerts.signed_in(user, "203.0.113.5", "Firefox", :browser)

      refute_email_sent()
      assert Repo.aggregate(where(SignIn, user_id: ^user.id), :count) == 2
    end

    test "a sign-in from a new address tells the account holder" do
      user = user_fixture()
      flush_emails()
      SecurityAlerts.signed_in(user, "203.0.113.5", "Firefox", :browser)

      SecurityAlerts.signed_in(user, "198.51.100.9", "Unknown Browser", :browser)

      assert_email_sent(fn email ->
        assert email.to == [{"", user.email}]
        assert email.subject == subject("New sign-in to your account")
        assert email.text_body =~ "198.51.100.9"
        assert email.text_body =~ "reset your password"
      end)
    end

    test "each unfamiliar address is reported, even within the same hour" do
      user = user_fixture()
      flush_emails()
      SecurityAlerts.signed_in(user, "203.0.113.5", "Firefox", :browser)

      SecurityAlerts.signed_in(user, "198.51.100.1", "Firefox", :browser)
      SecurityAlerts.signed_in(user, "198.51.100.2", "Firefox", :browser)

      assert_email_sent(fn email -> assert email.text_body =~ "198.51.100.1" end)
      assert_email_sent(fn email -> assert email.text_body =~ "198.51.100.2" end)
    end

    test "an address unused for 180 days counts as new again, and old rows are pruned" do
      user = user_fixture()
      flush_emails()
      SecurityAlerts.signed_in(user, "203.0.113.5", "Firefox", :browser)
      SecurityAlerts.signed_in(user, "198.51.100.9", "Firefox", :browser)
      assert_email_sent()

      Repo.update_all(where(SignIn, user_id: ^user.id, ip_address: "198.51.100.9"),
        set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -181 * 86_400)]
      )

      # The rows are aged 181 days; the hourly notice throttle runs on the real
      # clock, so stand in for the time that would have passed.
      QuantumBilling.RateLimiter.reset(
        {:security_notice, {:new_address, "198.51.100.9"}, user.id}
      )

      SecurityAlerts.signed_in(user, "198.51.100.9", "Firefox", :browser)

      assert_email_sent(subject: subject("New sign-in to your account"))
      refute Repo.exists?(where(SignIn, [s], s.inserted_at < ago(180, "day")))
    end
  end

  describe "failed sign-ins" do
    test "tell the holder once an hour, and say nothing about an unknown address" do
      user = user_fixture()
      flush_emails()

      SecurityAlerts.failed_passwords(user.email, "203.0.113.7")
      assert_email_sent(subject: subject("Failed sign-in attempts on your account"))

      SecurityAlerts.failed_passwords(user.email, "203.0.113.7")
      refute_email_sent()

      SecurityAlerts.failed_passwords(
        "nobody-#{System.unique_integer()}@example.com",
        "203.0.113.7"
      )

      refute_email_sent()
    end

    test "failed two-factor codes say the password is known" do
      user = user_fixture()
      flush_emails()

      SecurityAlerts.failed_two_factor(user, "203.0.113.7")

      assert_email_sent(fn email -> assert email.text_body =~ "correct password" end)
    end

    test "switching two-factor off is reported to the holder" do
      user = user_fixture()
      flush_emails()

      SecurityAlerts.two_factor_disabled(user)

      assert_email_sent(subject: subject("Two-factor authentication was turned off"))
    end
  end

  describe "administration and exports" do
    setup do
      context = %{business: Businesses.default!(), owner: owner_fixture(), staff: user_fixture()}
      flush_emails()
      context
    end

    test "go to every owner and no staff", %{business: business, owner: owner, staff: staff} do
      other_owner = owner_fixture()
      flush_emails()

      SecurityAlerts.admin_event(business, owner, "made jo@example.com an owner")

      recipients =
        Stream.repeatedly(fn ->
          receive do
            {:email, email} -> email.to
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(& &1)
        |> List.flatten()
        |> Enum.map(&elem(&1, 1))

      assert owner.email in recipients
      assert other_owner.email in recipients
      refute staff.email in recipients
    end

    test "a full backup always alerts", %{business: business, owner: owner} do
      SecurityAlerts.exported(business, owner, :backup)

      assert_email_sent(fn email -> assert email.subject =~ "downloaded a full backup" end)
    end

    test "other exports alert once, on the thirtieth within an hour", %{
      business: business,
      staff: staff
    } do
      for _ <- 1..29, do: SecurityAlerts.exported(business, staff, "report export")
      refute_email_sent()

      SecurityAlerts.exported(business, staff, "report export")
      assert_email_sent(fn email -> assert email.subject =~ "30 exports within an hour" end)

      SecurityAlerts.exported(business, staff, "report export")
      refute_email_sent()
    end
  end
end
