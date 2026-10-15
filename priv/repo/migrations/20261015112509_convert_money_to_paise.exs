defmodule QuantumBilling.Repo.Migrations.ConvertMoneyToPaise do
  @moduledoc """
  Money moves from whole rupees to integer paise, and quantities from whole
  numbers to three decimal places.

  Every money column becomes `bigint` holding paise: in paise a 32-bit column
  stops at about ₹2.1 crore. Column names stay; only the unit changes, so
  ₹11,800 is stored as 1180000 and reads back exactly. Credit notes, the one
  table that kept `numeric(12,2)` rupees, join the rest.

  `down/0` converts back for a development database, but rounds away any paise
  entered since — take a backup before running this in production.
  """
  use Ecto.Migration

  @rupee_columns %{
    "invoices" =>
      ~w(taxable_value cgst_amount sgst_amount igst_amount cess_amount round_off grand_total),
    "invoice_items" => ~w(rate amount),
    "clients" => ~w(credit_limit opening_balance outstanding),
    "organization_settings" => ~w(ewb_threshold_value)
  }

  @note_columns ~w(subtotal tax_total grand_total)

  @quantity_columns [{"invoices", "total_quantity", 0}, {"invoice_items", "quantity", 1}]

  def up do
    for {table, columns} <- @rupee_columns, column <- columns do
      execute "ALTER TABLE #{table} ALTER COLUMN #{column} TYPE bigint USING #{column}::bigint * 100"
    end

    execute "ALTER TABLE organization_settings ALTER COLUMN ewb_threshold_value SET DEFAULT 5000000"

    for column <- @note_columns do
      execute "ALTER TABLE credit_notes ALTER COLUMN #{column} DROP DEFAULT"

      execute "ALTER TABLE credit_notes ALTER COLUMN #{column} TYPE bigint USING round(#{column} * 100)::bigint"

      execute "ALTER TABLE credit_notes ALTER COLUMN #{column} SET DEFAULT 0"
    end

    for {table, column, _default} <- @quantity_columns do
      execute "ALTER TABLE #{table} ALTER COLUMN #{column} TYPE numeric(15,3)"
    end
  end

  def down do
    for {table, column, default} <- @quantity_columns do
      execute "ALTER TABLE #{table} ALTER COLUMN #{column} TYPE integer USING round(#{column})::integer"
      execute "ALTER TABLE #{table} ALTER COLUMN #{column} SET DEFAULT #{default}"
    end

    for column <- @note_columns do
      execute "ALTER TABLE credit_notes ALTER COLUMN #{column} DROP DEFAULT"

      execute "ALTER TABLE credit_notes ALTER COLUMN #{column} TYPE numeric(12,2) USING #{column} / 100.0"

      execute "ALTER TABLE credit_notes ALTER COLUMN #{column} SET DEFAULT 0.0"
    end

    execute "ALTER TABLE organization_settings ALTER COLUMN ewb_threshold_value SET DEFAULT 50000"

    for {table, columns} <- @rupee_columns, column <- columns do
      execute "ALTER TABLE #{table} ALTER COLUMN #{column} TYPE integer USING round(#{column} / 100.0)::integer"
    end
  end
end
