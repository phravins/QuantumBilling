defmodule QuantumBilling.GST do
  @moduledoc """
  Format rules for the Indian GST identifiers, shared by every schema that
  validates them.

  A GSTIN is fifteen characters and *contains* the PAN:

      2 7 A A B C A 1 2 3 4 A 1 Z 5
      │─┘ │───────────────┘ │ │ └── checksum
      │   │                 │ └──── always "Z"
      │   │                 └────── entity number for that PAN in the state
      │   └──────────────────────── the 10-character PAN
      └──────────────────────────── state code

  That structure is why `pan_from_gstin/1` exists: the two fields on a form can
  be cross-checked against each other rather than validated in isolation.
  """

  import Ecto.Changeset

  # Five letters, four digits, one letter.
  @pan_format ~r/^[A-Z]{5}\d{4}[A-Z]$/

  # State code, PAN, entity number, literal Z, checksum.
  @gstin_format ~r/^\d{2}[A-Z]{5}\d{4}[A-Z][A-Z\d]Z[A-Z\d]$/

  @doc "The GSTIN format. Fifteen characters — a sixteenth is not a GSTIN."
  def gstin_format, do: @gstin_format

  @doc "The PAN format."
  def pan_format, do: @pan_format

  @doc """
  The PAN embedded in a GSTIN, or `nil` when the GSTIN is not well formed.

  ## Examples

      iex> QuantumBilling.GST.pan_from_gstin("27AABCA1234A1Z5")
      "AABCA1234A"

      iex> QuantumBilling.GST.pan_from_gstin("nonsense")
      nil

  """
  def pan_from_gstin(gstin) when is_binary(gstin) do
    if Regex.match?(@gstin_format, gstin), do: binary_part(gstin, 2, 10)
  end

  def pan_from_gstin(_gstin), do: nil

  @doc "True when `gstin` is a well-formed GSTIN."
  def valid_gstin?(gstin) when is_binary(gstin), do: Regex.match?(@gstin_format, gstin)
  def valid_gstin?(_gstin), do: false

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
  Checks that a PAN matches the one embedded in the GSTIN.

  Only runs when both are present and the GSTIN is well formed — a malformed
  GSTIN is already reported by `validate_gstin/3`, and repeating the complaint
  on the PAN field would be noise.
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
