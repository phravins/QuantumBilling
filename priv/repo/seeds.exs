# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# It is idempotent: re-running it leaves existing records alone.

alias QuantumBilling.Accounts
alias QuantumBilling.Accounts.User
alias QuantumBilling.Repo

demo = %{
  username: "admin",
  email: "admin@osworks.in",
  password: "admin123"
}

# A ready-to-use account so the app can be signed into before real tenant data
# exists. Confirmed on insert — it never receives a confirmation email.
case Accounts.get_user_by_email(demo.email) do
  nil ->
    {:ok, _user} =
      %User{}
      |> User.registration_changeset(demo)
      |> User.confirm_changeset()
      |> Repo.insert()

    IO.puts("""

    Demo account created:

      email:    #{demo.email}
      username: #{demo.username}
      password: #{demo.password}
    """)

  _user ->
    IO.puts("Demo account #{demo.email} already exists — nothing to do.")
end
