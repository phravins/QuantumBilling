# Script for populating the database with demo data.
# Run with: mix run priv/repo/seeds.exs

alias QuantumBilling.Repo
alias QuantumBilling.Clients
alias QuantumBilling.Invoices
alias QuantumBilling.Settings
alias QuantumBilling.Settings.Organization

# 1. Organization Settings
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
Organization.changeset(org, org_attrs, :invoice) |> Repo.update()

IO.puts("✓ Organization settings initialized.")

# 2. Demo Clients
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

created_clients =
  Enum.map(clients_data, fn attrs ->
    case Clients.create_client(attrs) do
      {:ok, client} -> client
      {:error, _cs} -> Repo.get_by!(QuantumBilling.Clients.Client, name: attrs.name)
    end
  end)

IO.puts("✓ Sample clients seeded (#{length(created_clients)} clients).")

# 3. Demo Invoices
c1 = Enum.find(created_clients, &(&1.name == "Infosys Technologies Ltd"))
c2 = Enum.find(created_clients, &(&1.name == "Reliance Retail Ltd"))
c3 = Enum.find(created_clients, &(&1.name == "Tata Consultancy Services"))

sample_invoices = [
  %{
    client_id: c1.id,
    client_name: c1.name,
    client_gstin: c1.gstin,
    client_billing_address: "Electronics City, Hosur Road, Bengaluru, Karnataka (29) - 560100",
    place_of_supply: "Karnataka (29)",
    invoice_date: ~D[2026-03-01],
    due_date: ~D[2026-03-31],
    status: "E-Invoice Generated",
    items: [
      %{
        description: "Enterprise Software License",
        hsn_sac: "998314",
        quantity: 1,
        unit: "Pcs",
        rate: 150_000,
        tax_rate: 18,
        position: 1
      },
      %{
        description: "Cloud Integration Consultancy",
        hsn_sac: "998313",
        quantity: 40,
        unit: "Hrs",
        rate: 2500,
        tax_rate: 18,
        position: 2
      }
    ]
  },
  %{
    client_id: c2.id,
    client_name: c2.name,
    client_gstin: c2.gstin,
    client_billing_address: "Maker Chambers IV, Nariman Point, Mumbai, Maharashtra (27) - 400021",
    place_of_supply: "Maharashtra (27)",
    invoice_date: ~D[2026-03-05],
    due_date: ~D[2026-03-20],
    status: "Pending E-Invoice",
    items: [
      %{
        description: "POS Terminal Billing Module",
        hsn_sac: "998314",
        quantity: 5,
        unit: "Nos",
        rate: 35000,
        tax_rate: 18,
        position: 1
      }
    ]
  },
  %{
    client_id: c3.id,
    client_name: c3.name,
    client_gstin: c3.gstin,
    client_billing_address: "SIPCOT IT Park, Siruseri, Chennai, Tamil Nadu (33) - 603103",
    place_of_supply: "Tamil Nadu (33)",
    invoice_date: ~D[2026-03-10],
    due_date: ~D[2026-04-09],
    status: "Draft",
    items: [
      %{
        description: "Annual Maintenance & Support Contract",
        hsn_sac: "998315",
        quantity: 1,
        unit: "Nos",
        rate: 240_000,
        tax_rate: 18,
        position: 1
      }
    ]
  }
]

Enum.each(sample_invoices, fn inv_attrs ->
  case Invoices.create_invoice(inv_attrs) do
    {:ok, inv} ->
      IO.puts("  + Created invoice #{inv.invoice_number} for #{inv.client_name}")
      # Seed an audit log for invoice creation
      QuantumBilling.Audit.log_event("invoice.create", "Invoice", inv.id,
        details: %{invoice_number: inv.invoice_number, amount: inv.grand_total}
      )

    {:error, cs} ->
      IO.puts("  ! Failed to create invoice: #{inspect(cs.errors)}")
  end
end)

# 4. Seed Recurring Profiles
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

# 5. Seed Credit Notes
invoices = Invoices.list_invoices()

if first_invoice = List.first(invoices) do
  db_invoice = Invoices.get_invoice!(first_invoice.id)

  {:ok, _cn} =
    QuantumBilling.CreditNotes.create_credit_note_for_invoice(db_invoice, %{
      "note_type" => "Credit",
      "reason" => "Annual Volume Discount Adjustment"
    })

  IO.puts("✓ Seeded Credit Note.")
end

# 6. Seed Audit Logs
QuantumBilling.Audit.log_event("system.bootstrap", "Database", "1",
  details: %{mode: "seeds_populated"}
)

QuantumBilling.Audit.log_event("settings.update", "Organization", "1",
  details: %{gstin: org_attrs.gstin}
)

IO.puts("✓ Demo setup completed successfully!")
