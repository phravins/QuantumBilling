defmodule Mix.Tasks.Qb.Admin.Grant do
  @shortdoc "Makes a user a super admin of the installation, or revokes it"

  @moduledoc """
  Grants or revokes super admin, which opens the Admin Panel: version, config,
  health, maintenance mode and the sidebar layout for everyone.

      $ mix qb.admin.grant someone@example.com
      $ mix qb.admin.grant someone@example.com --revoke

  This is the only way to set it: no page in the app can, so no one can make
  themselves an admin. In a release, run the same through `bin/quantum_billing eval`
  with `QuantumBilling.Accounts.set_admin/2`.
  """
  use Mix.Task

  @requirements ["app.start"]

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: [revoke: :boolean]) do
      {opts, [email], []} -> set(email, !opts[:revoke])
      _ -> Mix.raise("Usage: mix qb.admin.grant EMAIL [--revoke]")
    end
  end

  defp set(email, admin?) do
    case QuantumBilling.Accounts.get_user_by_email(email) do
      nil ->
        Mix.raise("No user with the email #{email}")

      user ->
        {:ok, _user} = QuantumBilling.Accounts.set_admin(user, admin?)
        verb = if admin?, do: "is now", else: "is no longer"
        Mix.shell().info("#{email} #{verb} a super admin.")
    end
  end
end
