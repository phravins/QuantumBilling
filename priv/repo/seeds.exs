# Script for creating the first sign-in account and business 1's company settings.
# Run with: mix run priv/repo/seeds.exs

alias QuantumBilling.Accounts
alias QuantumBilling.Accounts.User
alias QuantumBilling.Repo
alias QuantumBilling.Settings
alias QuantumBilling.Settings.Organization

# 1. Sign-in account. Configure all three values in the environment or .env.
# Validate before writing any seed data; never create an account with defaults.
[admin_email, admin_password, admin_username] =
  Enum.map(~w(SEED_ADMIN_EMAIL SEED_ADMIN_PASSWORD SEED_ADMIN_USERNAME), fn name ->
    value = System.get_env(name)

    if is_nil(value) or String.trim(value) == "" do
      raise "Set #{name} in your environment or .env before running seeds."
    end

    value
  end)

case Accounts.get_user_by_email(admin_email) do
  nil ->
    {:ok, user} =
      Accounts.register_user_with_password(%{
        username: admin_username,
        email: admin_email,
        password: admin_password,
        password_confirmation: admin_password
      })

    # Confirmed directly: an unconfirmed account is refused at login.
    {:ok, _confirmed} = user |> User.confirm_changeset() |> Repo.update()

    IO.puts("\u2713 Default account created: #{admin_email}")

  _already_there ->
    IO.puts("\u2713 Default account already present: #{admin_email}")
end

# Everything below is the first business's own data.
Repo.put_business(QuantumBilling.Businesses.default!())

# 2. Organization Settings
org_attrs = %{
  company_name: "Quantum Billing Tech Solutions Pvt Ltd",
  trade_name: "QuantumBilling",
  address: "Unit 401, Tech Park, BKC, Bandra East",
  city: "Mumbai",
  pincode: "400051",
  phone: "+91 9876543210",
  email: "billing@quantumbilling.in",
  gstin: "27AABCU9603R1ZM",
  pan: "AABCU9603R",
  state: "Maharashtra (27)",
  currency: "INR (₹) - Indian Rupee",
  invoice_prefix: "INV",
  invoice_next_number: 1001,
  default_gst_rate: 18
}

org = Settings.ensure_organization()
Organization.changeset(org, org_attrs, :general) |> Repo.update()

# Seed the invoice counter only on a fresh row, or new numbers collide.
if Repo.aggregate(QuantumBilling.Invoices.Invoice, :count) == 0 do
  {:ok, _org} = Organization.changeset(org, org_attrs, :invoice) |> Repo.update()
else
  IO.puts("✓ Invoice numbering left at #{org.invoice_next_number}.")
end

IO.puts("✓ Organization settings initialized. Add your own clients and invoices in the app.")
