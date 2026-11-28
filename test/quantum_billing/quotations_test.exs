defmodule QuantumBilling.QuotationsTest do
  use QuantumBilling.DataCase, async: false

  import QuantumBilling.AccountsFixtures

  alias QuantumBilling.Accounts.Scope
  alias QuantumBilling.Audit.AuditLog
  alias QuantumBilling.Businesses
  alias QuantumBilling.Compliance.GSTNExporter
  alias QuantumBilling.Invoices
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.Quotations
  alias QuantumBilling.Quotations.Quotation
  alias QuantumBilling.Reports
  alias QuantumBilling.Settings
  alias QuantumBilling.TaxRates

  # Maharashtra is the company's own state, so "Maharashtra (27)" is
  # intra-state and anything else inter-state.
  setup do
    {:ok, organization} =
      Settings.update_section(
        Settings.get_organization(),
        %{
          "company_name" => "ABC Solutions Private Limited",
          "gstin" => "27AABCA1234A1Z5",
          "pan" => "AABCA1234A",
          "state" => "Maharashtra (27)",
          "address" => "123 Business Park, Mumbai"
        },
        :general
      )

    scope = %{Scope.for_user(user_fixture()) | business: Repo.business()}
    %{organization: organization, scope: scope}
  end

  defp item(over \\ %{}) do
    Map.merge(
      %{
        "description" => "Web Development Services",
        "hsn_sac" => "998313",
        "quantity" => "2",
        "unit" => "Nos",
        "rate" => "25000",
        "tax_rate" => "18",
        "position" => "0"
      },
      over
    )
  end

  defp attrs(over) do
    today = Quotations.today()

    Map.merge(
      %{
        "quotation_date" => Date.to_iso8601(today),
        "valid_until" => Date.to_iso8601(Date.add(today, 30)),
        "place_of_supply" => "Maharashtra (27)",
        "client_name" => "V2V Technologies",
        "items" => %{"0" => item()}
      },
      over
    )
  end

  defp quotation_fixture(scope, over \\ %{}) do
    {:ok, quotation} = Quotations.create_quotation(scope, attrs(over))
    quotation
  end

  defp accepted_fixture(scope, over \\ %{}) do
    {:ok, quotation} = Quotations.accept(scope, quotation_fixture(scope, over))
    quotation
  end

  # Stored straight to the database: the changeset would not let a quotation
  # be dated in the past only to be expired.
  defp expire(%Quotation{} = quotation) do
    today = Quotations.today()

    quotation
    |> Ecto.Changeset.change(
      quotation_date: Date.add(today, -40),
      valid_until: Date.add(today, -1)
    )
    |> Repo.update!()
  end

  defp audited?(action, %Quotation{id: id}) do
    Repo.exists?(
      from l in AuditLog,
        where:
          l.action == ^to_string(action) and l.resource_type == "Quotation" and
            l.resource_id == ^to_string(id)
    )
  end

  defp conversion_params(quotation) do
    quotation
    |> Quotations.invoice_params()
    |> Map.put("invoice_date", Date.to_iso8601(Quotations.today()))
  end

  describe "create_quotation/2" do
    test "computes totals and takes the next QT number", %{scope: scope} do
      quotation = quotation_fixture(scope)

      assert quotation.number == "QT-0001"
      assert quotation.status == "Draft"
      assert quotation.taxable_value == 5_000_000
      assert quotation.cgst_amount == 450_000
      assert quotation.sgst_amount == 450_000
      assert quotation.igst_amount == 0
      assert quotation.grand_total == 5_900_000
      assert quotation.company_state == "Maharashtra (27)"
      assert audited?(:create_quotation, quotation)

      assert quotation_fixture(scope).number == "QT-0002"
    end

    test "leaves the invoice series alone, and the invoice series leaves it alone",
         %{scope: scope} do
      invoice_number = Settings.next_invoice_number(Settings.get_organization())

      quotation_fixture(scope)
      assert Settings.next_invoice_number(Settings.get_organization()) == invoice_number

      {:ok, _invoice} =
        Invoices.create_invoice(%{
          "invoice_date" => Date.to_iso8601(Quotations.today()),
          "place_of_supply" => "Maharashtra (27)",
          "client_name" => "V2V Technologies",
          "items" => %{"0" => item()}
        })

      assert Settings.next_quotation_number(Settings.get_organization()) == "QT-0002"
    end

    test "ignores a status in the params", %{scope: scope} do
      assert quotation_fixture(scope, %{"status" => "Accepted"}).status == "Draft"
    end

    test "rejects a validity date before the quotation date", %{scope: scope} do
      today = Quotations.today()

      assert {:error, changeset} =
               Quotations.create_quotation(
                 scope,
                 attrs(%{"valid_until" => Date.to_iso8601(Date.add(today, -1))})
               )

      assert %{valid_until: [_]} = errors_on(changeset)
    end

    test "rejects a quotation with no lines", %{scope: scope} do
      assert {:error, changeset} = Quotations.create_quotation(scope, attrs(%{"items" => %{}}))
      refute changeset.valid?
    end
  end

  describe "update_quotation/3" do
    test "edits Draft quotations and sends revised Sent quotations back to Draft", %{scope: scope} do
      quotation = quotation_fixture(scope)

      assert {:ok, updated} =
               Quotations.update_quotation(scope, quotation, %{
                 "client_name" => "New Client",
                 "status" => "Accepted",
                 "number" => "HACKED-1"
               })

      assert updated.client_name == "New Client"
      assert updated.status == "Draft"
      assert updated.number == quotation.number

      {:ok, sent} = Quotations.mark_sent(scope, updated)
      assert sent.sent_revision == sent.revision
      assert {:ok, revised} = Quotations.update_quotation(scope, sent, %{"remarks" => "Revised"})
      assert revised.status == "Draft"
      assert revised.revision == sent.revision + 1
      assert revised.sent_revision == sent.revision
      assert Quotation.needs_resend?(revised)
      refute Quotation.answerable?(revised)

      assert {:error, :invalid_transition} = Quotations.accept(scope, revised)
      assert {:error, :invalid_transition} = Quotations.decline(scope, revised)

      {:ok, resent} = Quotations.mark_sent(scope, revised)
      assert resent.sent_revision == resent.revision
      assert Quotation.answerable?(resent)
    end

    test "is locked once Accepted or Declined", %{scope: scope} do
      accepted = accepted_fixture(scope)
      {:ok, declined} = Quotations.decline(scope, quotation_fixture(scope))

      for quotation <- [accepted, declined] do
        assert Quotations.update_quotation(scope, quotation, %{"client_name" => "X"}) ==
                 {:error, :locked}
      end
    end
  end

  describe "status transitions" do
    test "Draft → Sent → Accepted, each audited", %{scope: scope} do
      quotation = quotation_fixture(scope)

      assert {:ok, %{status: "Sent"} = sent} = Quotations.mark_sent(scope, quotation)
      assert audited?(:quotation_sent, sent)

      assert {:ok, %{status: "Accepted"} = accepted} = Quotations.accept(scope, sent)
      assert audited?(:quotation_accepted, accepted)
    end

    test "Draft → Declined, audited", %{scope: scope} do
      assert {:ok, %{status: "Declined"} = declined} =
               Quotations.decline(scope, quotation_fixture(scope))

      assert audited?(:quotation_declined, declined)
    end

    test "refuses moves its status doesn't allow", %{scope: scope} do
      accepted = accepted_fixture(scope)

      assert Quotations.mark_sent(scope, accepted) == {:error, :invalid_transition}
      assert Quotations.decline(scope, accepted) == {:error, :invalid_transition}
      assert Quotations.accept(scope, accepted) == {:error, :invalid_transition}
    end

    test "checks the stored status, not the caller's copy", %{scope: scope} do
      quotation = quotation_fixture(scope)
      {:ok, _declined} = Quotations.decline(scope, quotation)

      # `quotation` still says Draft.
      assert Quotations.accept(scope, quotation) == {:error, :invalid_transition}
    end

    test "an expired quotation can be declined but not accepted or sent", %{scope: scope} do
      quotation = scope |> quotation_fixture() |> expire()

      assert Quotations.accept(scope, quotation) == {:error, :invalid_transition}
      assert Quotations.mark_sent(scope, quotation) == {:error, :invalid_transition}
      assert {:ok, %{status: "Declined"}} = Quotations.decline(scope, quotation)
    end
  end

  describe "Expired" do
    test "is Draft or Sent past valid_until", %{scope: scope} do
      today = Quotations.today()
      quotation = quotation_fixture(scope)

      assert Quotation.effective_status(quotation, today) == "Draft"

      assert Quotation.effective_status(quotation, Date.add(quotation.valid_until, 1)) ==
               "Expired"

      accepted = accepted_fixture(scope)
      assert Quotation.effective_status(accepted, Date.add(accepted.valid_until, 1)) == "Accepted"
    end

    test "has its own filter and count, and leaves Draft", %{scope: scope} do
      today = Quotations.today()
      current = quotation_fixture(scope)
      expired = scope |> quotation_fixture() |> expire()

      ids = fn status ->
        Enum.map(Quotations.page(status: status, today: today).rows, & &1.id)
      end

      assert ids.("Expired") == [expired.id]
      assert ids.("Draft") == [current.id]
      assert Enum.sort(ids.("All")) == Enum.sort([current.id, expired.id])
      assert %{"Draft" => 1, "Expired" => 1} = Quotations.status_counts(today)
    end

    test "extending valid_until revives it", %{scope: scope} do
      expired = scope |> quotation_fixture() |> expire()
      later = Date.to_iso8601(Date.add(Quotations.today(), 10))

      assert {:ok, revived} =
               Quotations.update_quotation(scope, expired, %{"valid_until" => later})

      assert Quotation.effective_status(revived, Quotations.today()) == "Draft"
      assert {:ok, %{status: "Accepted"}} = Quotations.accept(scope, revived)
    end
  end

  describe "page/1" do
    test "searches by number and client name", %{scope: scope} do
      first = quotation_fixture(scope, %{"client_name" => "Bluewave Retail"})
      _other = quotation_fixture(scope, %{"client_name" => "Green Leaf"})

      assert [%{id: id}] = Quotations.page(search: "bluewave").rows
      assert id == first.id
      assert [%{id: ^id}] = Quotations.page(search: first.number).rows
    end
  end

  describe "delete_quotation/2" do
    test "deletes an unconverted quotation and audits it", %{scope: scope} do
      quotation = quotation_fixture(scope)

      assert {:ok, _} = Quotations.delete_quotation(scope, quotation)
      assert Quotations.get_quotation(quotation.id) == nil
      assert audited?(:delete_quotation, quotation)
    end

    test "keeps a converted quotation", %{scope: scope} do
      quotation = accepted_fixture(scope)

      {:ok, _invoice} =
        Invoices.create_invoice(conversion_params(quotation), quotation_id: quotation.id)

      assert Quotations.delete_quotation(scope, quotation) == {:error, :converted}
    end
  end

  # The same lines and context through both changesets give the same money.
  describe "tax parity with invoices" do
    @money ~w(total_items total_quantity taxable_value cgst_amount sgst_amount igst_amount
              cess_amount vat_amount tax_breakdown round_off grand_total)a

    defp totals_of(changeset) do
      changeset |> Ecto.Changeset.apply_changes() |> Map.take(@money)
    end

    defp both(organization, items, over) do
      trusted = Quotations.preview_trusted(organization, %Quotation{})

      quotation =
        Quotations.change_quotation(%Quotation{}, attrs(Map.put(over, "items", items)), trusted)

      invoice =
        Invoices.change_invoice(
          %Invoice{},
          Map.merge(
            %{
              "invoice_date" => Date.to_iso8601(Quotations.today()),
              "place_of_supply" => "Maharashtra (27)",
              "client_name" => "V2V Technologies",
              "items" => items
            },
            over
          ),
          trusted
        )

      {totals_of(quotation), totals_of(invoice)}
    end

    @gst_items %{
      "0" => %{
        "description" => "Design",
        "quantity" => "3",
        "unit" => "Nos",
        "rate" => "1234.50",
        "tax_rate" => "18",
        "position" => "0"
      },
      "1" => %{
        "description" => "Hosting",
        "quantity" => "1.5",
        "unit" => "Nos",
        "rate" => "999",
        "tax_rate" => "5",
        "position" => "1"
      }
    }

    test "GST intra-state", %{organization: organization} do
      {quotation, invoice} = both(organization, @gst_items, %{})
      assert quotation == invoice
      assert quotation.cgst_amount > 0 and quotation.igst_amount == 0
    end

    test "GST inter-state", %{organization: organization} do
      {quotation, invoice} =
        both(organization, @gst_items, %{"place_of_supply" => "Karnataka (29)"})

      assert quotation == invoice
      assert quotation.igst_amount > 0 and quotation.cgst_amount == 0
    end

    test "VAT" do
      owner_user = owner_fixture()
      business = Businesses.default!()

      owner =
        Scope.put_membership(
          Scope.for_user(owner_user),
          Businesses.get_membership(owner_user, business.id)
        )

      {:ok, organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{"tax_regime" => "vat", "vat_country" => "AE", "vat_number" => "100123456700003"},
          :tax
        )

      {:ok, _rates} = TaxRates.ensure_presets(owner, "AE")
      rate = Enum.find(TaxRates.list_rates(), &(&1.rate_bp > 0))

      items = %{
        "0" => %{
          "description" => "Consulting",
          "quantity" => "2",
          "unit" => "Nos",
          "rate" => "1500",
          "tax_rate_id" => to_string(rate.id),
          "position" => "0"
        }
      }

      {quotation, invoice} =
        both(organization, items, %{
          "place_of_supply" => nil,
          "client_tax_number" => "100200300400003"
        })

      assert quotation == invoice
      assert quotation.vat_amount > 0
    end
  end

  describe "conversion" do
    test "links the invoice to the quotation, once", %{scope: scope} do
      quotation = accepted_fixture(scope)
      assert Quotations.convertible?(quotation)

      assert {:ok, invoice} =
               Invoices.create_invoice(conversion_params(quotation), quotation_id: quotation.id)

      assert invoice.quotation_id == quotation.id
      assert invoice.grand_total == quotation.grand_total
      assert invoice.client_name == quotation.client_name
      assert length(invoice.items) == length(quotation.items)

      reloaded = Quotations.get_quotation(quotation.id)
      assert reloaded.invoice.id == invoice.id
      refute Quotations.convertible?(reloaded)

      assert Invoices.create_invoice(conversion_params(quotation), quotation_id: quotation.id) ==
               {:error, :quotation_not_convertible}
    end

    test "refuses a quotation that isn't Accepted", %{scope: scope} do
      for quotation <- [
            quotation_fixture(scope),
            elem(Quotations.decline(scope, quotation_fixture(scope)), 1)
          ] do
        refute Quotations.convertible?(quotation)

        assert Invoices.create_invoice(conversion_params(quotation), quotation_id: quotation.id) ==
                 {:error, :quotation_not_convertible}
      end
    end

    test "never takes quotation_id from the params", %{scope: scope} do
      quotation = accepted_fixture(scope)

      {:ok, invoice} =
        quotation
        |> conversion_params()
        |> Map.put("quotation_id", to_string(quotation.id))
        |> Invoices.create_invoice()

      assert invoice.quotation_id == nil
      assert Quotations.convertible?(Quotations.get_quotation(quotation.id))
    end
  end

  describe "tax figures" do
    test "a quotation is in none of them", %{scope: scope} do
      filters = Map.put(Reports.default_filters(), :date_range, "All Time")
      period = Calendar.strftime(Quotations.today(), "%m%Y")

      figures = fn ->
        {Invoices.totals(), Invoices.month_totals(), Reports.tax_rows(filters),
         GSTNExporter.generate_gstr1_json(period)}
      end

      before = figures.()

      _accepted = accepted_fixture(scope)
      _sent = scope |> quotation_fixture(%{"place_of_supply" => "Karnataka (29)"})

      assert figures.() == before
    end
  end
end
