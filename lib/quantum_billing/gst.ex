defmodule QuantumBilling.GST do
  @moduledoc """
  Format rules for Indian GST identifiers.

  A GSTIN is 15 characters: state code (2), PAN (10), entity number, `Z` and a
  checksum, so `pan_from_gstin/1` can cross-check the PAN field.
  """

  import Ecto.Changeset

  # Five letters, four digits, one letter.
  @pan_format ~r/^[A-Z]{5}\d{4}[A-Z]$/

  # State code, PAN, entity number, literal Z, checksum.
  @gstin_format ~r/^\d{2}[A-Z]{5}\d{4}[A-Z][A-Z\d]Z[A-Z\d]$/

  @doc """
  The PAN inside a GSTIN (`"27AABCA1234A1Z5"` gives `"AABCA1234A"`), or `nil` if malformed.
  """
  def pan_from_gstin(gstin) when is_binary(gstin) do
    if Regex.match?(@gstin_format, gstin), do: binary_part(gstin, 2, 10)
  end

  def pan_from_gstin(_gstin), do: nil

  @doc "True when `gstin` is a well-formed GSTIN."
  def valid_gstin?(gstin) when is_binary(gstin), do: Regex.match?(@gstin_format, gstin)
  def valid_gstin?(_gstin), do: false

  @doc """
  The two-digit code in a state label (`"Maharashtra (27)"` gives `"27"`), or `nil`.
  """
  def state_code(state) when is_binary(state) do
    case Regex.run(~r/\((\d{2})\)$/, state) do
      [_match, code] -> code
      _no_code -> nil
    end
  end

  def state_code(_state), do: nil

  @doc """
  Validates `field` as a GSTIN, upcasing it first so lower-case input is
  accepted rather than rejected on a technicality.
  """
  def validate_gstin(changeset, field, opts \\ []) do
    message = Keyword.get(opts, :message, "is not a valid GSTIN")

    changeset
    |> update_change(field, &upcase/1)
    |> validate_format(field, @gstin_format, message: message)
  end

  @doc """
  Validates `field` as a PAN, upcasing it first.
  """
  def validate_pan(changeset, field, opts \\ []) do
    message = Keyword.get(opts, :message, "is not a valid PAN")

    changeset
    |> update_change(field, &upcase/1)
    |> validate_format(field, @pan_format, message: message)
  end

  @doc """
  Checks the PAN matches the GSTIN's. Skipped when the GSTIN is malformed, which `validate_gstin/3` reports.
  """
  def validate_gstin_matches_pan(changeset, gstin_field, pan_field) do
    gstin = get_field(changeset, gstin_field)
    pan = get_field(changeset, pan_field)
    embedded = pan_from_gstin(gstin)

    if embedded && pan && embedded != pan do
      add_error(changeset, pan_field, "does not match the PAN in the GSTIN (#{embedded})")
    else
      changeset
    end
  end

  defp upcase(nil), do: nil
  defp upcase(value) when is_binary(value), do: value |> String.trim() |> String.upcase()
  defp upcase(value), do: value
end
