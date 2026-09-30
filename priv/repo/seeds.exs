# Script for populating the database with demo data.
# Run with: mix run priv/repo/seeds.exs

alias QuantumBilling.Accounts
alias QuantumBilling.Accounts.User
alias QuantumBilling.Repo
alias QuantumBilling.Clients
alias QuantumBilling.Invoices
alias QuantumBilling.Settings
alias QuantumBilling.Settings.Organization

# 1. Default sign-in account
#
# Everything below this is invisible without an account to sign in with, so the
# seeds create one. Both halves are overridable in the environment: a published
# default password is only safe on a machine nobody else can reach.
admin_email = System.get_env("SEED_ADMIN_EMAIL", "phravin@osworks.in")
admin_password = System.get_env("SEED_ADMIN_PASSWORD", "OSworks@26")
admin_username = System.get_env("SEED_ADMIN_USERNAME", "phravin")

case Accounts.get_user_by_email(admin_email) do
  nil ->
    {:ok, user} =
      Accounts.register_user_with_password(%{
        username: admin_username,
        email: admin_email,
        password: admin_password,
        password_confirmation: admin_password
      })

    # Confirmed here rather than by email. The confirmation link exists to
    # prove an address belongs to whoever typed it — nobody typed this one,
    # and an unconfirmed account is refused at login.
    {:ok, _confirmed} = user |> User.confirm_changeset() |> Repo.update()

    IO.puts("\u2713 Default account created: #{admin_email} / #{admin_password}")

  _already_there ->
    IO.puts("\u2713 Default account already present: #{admin_email}")
end

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

# The invoice counter is only seeded on a fresh row. Writing it on every run
# reset the series to 1001 while INV-1001 upward already existed, so the next
# invoice created collided with the unique index and could not be saved.
org =
  if Repo.aggregate(QuantumBilling.Invoices.Invoice, :count) == 0 do
    {:ok, org} = Organization.changeset(org, org_attrs, :invoice) |> Repo.update()
    org
  else
    IO.puts("✓ Invoice numbering left at #{org.invoice_next_number}.")
    org
  end

IO.puts("✓ Organization settings initialized.")

# 3. Demo Clients
clients_data = [
  %{
    client_type: "Registered Business",
    name: "Infosys Technologies Ltd",
    display_name: "Infosys",
    gstin: "29AAACI4166L1ZB",
    pan: "AAACI4166L",
    legal_name: "Infosys Technologies Limited",
    business_type: "Public Limited",
    category: "Customer",
    phone_country_code: "+91",
    phone: "9820011223",
    email: "accounts@infosys.com",
    billing_line1: "Electronics City, Hosur Road",
    billing_city: "Bengaluru",
    billing_state: "Karnataka (29)",
    billing_pin: "560100",
    shipping_same_as_billing: true,
    credit_limit: 500_000,
    payment_terms_days: 30
  },
  %{
    client_type: "Registered Business",
    name: "Reliance Retail Ltd",
    display_name: "Reliance Retail",
    gstin: "27AABCR5421M1Z2",
    pan: "AABCR5421M",
    legal_name: "Reliance Retail Limited",
    business_type: "Private Limited",
    category: "Customer",
    phone_country_code: "+91",
    phone: "9819922334",
    email: "vendor.billing@ril.com",
    billing_line1: "Maker Chambers IV, Nariman Point",
    billing_city: "Mumbai",
    billing_state: "Maharashtra (27)",
    billing_pin: "400021",
    shipping_same_as_billing: true,
    credit_limit: 1_000_000,
    payment_terms_days: 15
  },
  %{
    client_type: "Registered Business",
    name: "Tata Consultancy Services",
    display_name: "TCS",
    gstin: "33AAACT2800R1ZH",
    pan: "AAACT2800R",
    legal_name: "Tata Consultancy Services Ltd",
    business_type: "Public Limited",
    category: "Customer",
    phone_country_code: "+91",
    phone: "9840033445",
    email: "invoicing@tcs.com",
    billing_line1: "SIPCOT IT Park, Siruseri",
    billing_city: "Chennai",
    billing_state: "Tamil Nadu (33)",
    billing_pin: "603103",
    shipping_same_as_billing: true,
    credit_limit: 750_000,
    payment_terms_days: 30
  },
  %{
    client_type: "Unregistered",
    name: "Apex Retail Solutions",
    display_name: "Apex Retail",
    category: "Customer",
    phone_country_code: "+91",
    phone: "9711144556",
    email: "contact@apexretail.in",
    billing_line1: "Shop 12, Main Market, MG Road",
    billing_city: "Pune",
    billing_state: "Maharashtra (27)",
    billing_pin: "411001",
    shipping_same_as_billing: true
  }
]

# Looked up by name before creating. Creating first and falling back on error
# only worked for clients with a GSTIN, where the unique index refuses the
# second copy; an unregistered client has nothing unique about it, so every
# run of this file added another one.
created_clients =
  Enum.map(clients_data, fn attrs ->
    case Clients.get_client_by_name(attrs.name) do
      nil ->
        {:ok, client} = Clients.create_client(attrs)
        client

      client ->
        client
    end
  end)

IO.puts("✓ Sample clients seeded (#{length(created_clients)} clients).")

# 4. Demo Invoices
#
# Dated relative to today, not to fixed calendar days. The dashboard and the
# reports both window on "the last six months", so invoices pinned to a literal
# date scroll out of that window as time passes and leave every panel reading
# zero — which looks like a broken dashboard rather than stale sample data.
c1 = Enum.find(created_clients, &(&1.name == "Infosys Technologies Ltd"))
c2 = Enum.find(created_clients, &(&1.name == "Reliance Retail Ltd"))
c3 = Enum.find(created_clients, &(&1.name == "Tata Consultancy Services"))
c4 = Enum.find(created_clients, &(&1.name == "Apex Retail Solutions"))

today = Date.utc_today()

# `Date.add` in days rather than month arithmetic: it cannot land on the 31st
# of a 30-day month, and the exact day does not matter here — only the month
# the invoice falls into.
months_ago = fn count -> Date.add(today, -30 * count) end

client_address = fn client ->
  [client.billing_line1, client.billing_city, client.billing_state, client.billing_pin]
  |> Enum.reject(&(&1 in [nil, ""]))
  |> Enum.join(", ")
end

# The organisation is registered in Maharashtra, so a Maharashtra place of
# supply splits into CGST + SGST and everything else raises IGST. Both kinds
# are seeded on purpose: the dashboard's trend chart plots them as separate
# series, and with only one the second series is a flat line along the axis.
sample_invoices =
  [
    {c1, 5, "E-Invoice Generated", "Enterprise Software License", "998314", 1, "Pcs", 150_000},
    {c2, 5, "Paid", "POS Terminal Billing Module", "998314", 4, "Nos", 35_000},
    {c3, 4, "Paid", "Annual Maintenance & Support Contract", "998315", 1, "Nos", 240_000},
    {c2, 4, "E-Invoice Generated", "Retail Analytics Subscription", "998313", 6, "Nos", 18_000},
    {c1, 3, "Paid", "Cloud Integration Consultancy", "998313", 40, "Hrs", 2_500},
    {c4, 3, "E-Invoice Generated", "Billing Software Onboarding", "998314", 1, "Nos", 45_000},
    {c3, 2, "E-Invoice Generated", "GST Filing Automation Module", "998314", 2, "Nos", 95_000},
    {c2, 2, "Paid", "In-Store Kiosk Deployment", "998316", 3, "Nos", 52_000},
    {c1, 1, "E-Invoice Generated", "Data Migration Services", "998313", 25, "Hrs", 3_200},
    {c4, 1, "Pending E-Invoice", "Quarterly Support Retainer", "998315", 1, "Nos", 60_000},
    {c3, 0, "Pending E-Invoice", "Custom Report Builder", "998314", 1, "Nos", 125_000},
    {c2, 0, "Draft", "Loyalty Programme Integration", "998313", 12, "Hrs", 4_500}
  ]
  |> Enum.filter(fn {client, _, _, _, _, _, _, _} -> client end)
  |> Enum.map(fn {client, ago, status, description, hsn, qty, unit, rate} ->
    issued = months_ago.(ago)

    %{
      client_id: client.id,
      client_name: client.name,
      client_gstin: client.gstin,
      # The invoice keeps its own copy of these, as it does of the name and the
      # GSTIN: it is what the form shows when the invoice is opened again.
      client_pan: client.pan || QuantumBilling.GST.pan_from_gstin(client.gstin),
      client_email: client.email,
      client_state: client.billing_state,
      client_billing_address: client_address.(client),
      place_of_supply: client.billing_state,
      invoice_date: issued,
      due_date: Date.add(issued, client.payment_terms_days || 30),
      status: status,
      items: [
        %{
          description: description,
          hsn_sac: hsn,
          quantity: qty,
          unit: unit,
          rate: rate,
          tax_rate: 18,
          position: 1
        }
      ]
    }
  end)

# Seeded once. Invoice numbers come from a counter on the settings row, so a
# second run would not collide — it would simply mint a fresh set and double
# every figure on the dashboard.
if Repo.aggregate(QuantumBilling.Invoices.Invoice, :count) == 0 do
  Enum.each(sample_invoices, fn inv_attrs ->
    case Invoices.create_invoice(inv_attrs) do
      {:ok, inv} ->
        IO.puts("  + Created invoice #{inv.invoice_number} for #{inv.client_name}")

        QuantumBilling.Audit.log_event("invoice.create", "Invoice", inv.id,
          details: %{invoice_number: inv.invoice_number, amount: inv.grand_total}
        )

      {:error, cs} ->
        IO.puts("  ! Failed to create invoice: #{inspect(cs.errors)}")
    end
  end)
else
  IO.puts("\u2713 Invoices already present, left alone.")
end

# 5. Seed Recurring Profiles
alias QuantumBilling.Recurring

if c1 do
  case Recurring.create_profile(%{
         title: "Monthly Software License Retainer",
         client_id: c1.id,
         frequency: "Monthly",
         status: "Active",
         next_run_date: Date.add(Date.utc_today(), 15),
         items_json:
           Jason.encode!([
             %{
               "description" => "Enterprise Software Maintenance",
               "hsn_sac" => "998314",
               "quantity" => "1",
               "unit" => "Nos",
               "rate" => "150000",
               "tax_rate" => "18"
             }
           ])
       }) do
    {:ok, _profile} -> IO.puts("✓ Seeded Recurring Profile.")
    {:error, _} -> IO.puts("! Recurring profile already exists.")
  end
end

# 6. Seed Credit Notes
#
# Guarded. Credit notes net off receivables, and an ungated seed run added one
# more full-value note each time: after three runs the notes outweighed the
# invoices and the dashboard reported zero outstanding against six figures of
# unpaid bills.
if QuantumBilling.Repo.aggregate(QuantumBilling.CreditNotes.CreditNote, :count) == 0 do
  # Against an unpaid invoice, so the note has something to reduce. Picking
  # `List.first/1` blindly could land on one already marked Paid, where the
  # adjustment is excluded from receivables and the note looks like it did
  # nothing.
  unpaid =
    Invoices.list_invoices()
    |> Enum.find(&(&1.status not in ["Paid", "Cancelled"]))

  if unpaid do
    db_invoice = Invoices.get_invoice!(unpaid.id)

    {:ok, _cn} =
      QuantumBilling.CreditNotes.create_credit_note_for_invoice(db_invoice, %{
        "note_type" => "Credit",
        "reason" => "Annual Volume Discount Adjustment"
      })

    IO.puts("✓ Seeded Credit Note.")
  end
else
  IO.puts("✓ Credit notes already present, left alone.")
end

# 7. Seed Audit Logs
QuantumBilling.Audit.log_event("system.bootstrap", "Database", "1",
  details: %{mode: "seeds_populated"}
)

QuantumBilling.Audit.log_event("settings.update", "Organization", "1",
  details: %{gstin: org_attrs.gstin}
)

IO.puts("✓ Demo setup completed successfully!")
