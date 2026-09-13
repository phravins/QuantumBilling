defmodule QuantumBilling.Repo.Migrations.RegenerateInvoicePublicTokens do
  use Ecto.Migration

  @moduledoc """
  Replaces every invoice's public portal token with a cryptographically random
  one.

  The old tokens were `"tok_"` followed by 24 digits from `Enum.random/1`,
  which draws on the VM's pseudo-random generator. That generator is seeded per
  process and is not designed to resist prediction: seeing a handful of issued
  tokens is enough to reconstruct its state and derive the rest. Since the
  token alone opens `/pay/:token` — an invoice with the customer's name, GSTIN,
  address and amounts — it is a bearer credential and has to come from
  `:crypto.strong_rand_bytes/1`.

  Existing tokens are regenerated rather than left alone: a weak token that has
  already been handed out stays weak. Links already sent to customers stop
  working, which is the intended trade — the replacement link is one page load
  away, and the old one should not be honoured.
  """

  def up do
    %{rows: rows} = repo().query!("SELECT id FROM invoices", [], log: false)

    Enum.each(rows, fn [id] ->
      token = "inv_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      repo().query!("UPDATE invoices SET public_token = $1 WHERE id = $2", [token, id],
        log: false
      )
    end)
  end

  # Irreversible by design: the previous tokens were not stored anywhere else,
  # and reinstating weak ones would not be an improvement if they were.
  def down, do: :ok
end
