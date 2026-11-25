defmodule Mix.Tasks.Qb.Admin.GrantTest do
  # Not async: the Mix shell is global.
  use QuantumBilling.DataCase, async: false

  import QuantumBilling.AccountsFixtures

  alias Mix.Tasks.Qb.Admin.Grant
  alias QuantumBilling.Accounts

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "grants and revokes super admin" do
    user = user_fixture()

    Grant.run([user.email])
    assert Accounts.get_user!(user.id).is_admin
    assert_received {:mix_shell, :info, [message]}
    assert message =~ "is now a super admin"

    Grant.run([user.email, "--revoke"])
    refute Accounts.get_user!(user.id).is_admin
    assert_received {:mix_shell, :info, [message]}
    assert message =~ "is no longer"
  end

  test "refuses an unknown email or missing arguments" do
    assert_raise Mix.Error, ~r/No user/, fn -> Grant.run(["nobody@example.com"]) end
    assert_raise Mix.Error, ~r/Usage/, fn -> Grant.run([]) end
  end
end
