defmodule QuantumBilling.GSTTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias QuantumBilling.GST

  defp changeset(attrs) do
    types = %{gstin: :string, pan: :string}
    cast({%{gstin: nil, pan: nil}, types}, attrs, Map.keys(types))
  end

  defp errors(changeset), do: traverse_errors(changeset, fn {msg, _opts} -> msg end)

  describe "valid_gstin?/1" do
    test "accepts a well-formed GSTIN" do
      assert GST.valid_gstin?("27AABCA1234A1Z5")
      assert GST.valid_gstin?("29AABCU9603R1ZM")
    end

    test "rejects a sixteen-character GSTIN" do
      # This exact string was a malformed fixture found earlier in the project.
      refute GST.valid_gstin?("27AAACPJ8542D1ZS")
    end

    test "rejects the wrong shape" do
      # Missing the mandatory Z in the fourteenth position.
      refute GST.valid_gstin?("27AABCA1234A1X5")
      # PAN only.
      refute GST.valid_gstin?("AABCA1234A")
      refute GST.valid_gstin?("")
      refute GST.valid_gstin?(nil)
    end
  end

  describe "pan_from_gstin/1" do
    test "extracts the embedded PAN" do
      assert GST.pan_from_gstin("27AABCA1234A1Z5") == "AABCA1234A"
      assert GST.pan_from_gstin("29AABCU9603R1ZM") == "AABCU9603R"
    end

    test "is nil for anything that is not a GSTIN" do
      assert GST.pan_from_gstin("nonsense") == nil
      assert GST.pan_from_gstin(nil) == nil
    end

    test "what it extracts is itself a valid PAN" do
      pan = GST.pan_from_gstin("27AABCA1234A1Z5")

      assert Regex.match?(GST.pan_format(), pan)
    end
  end

  describe "validate_gstin/3" do
    test "accepts a valid GSTIN and upcases it" do
      changeset = changeset(%{gstin: "27aabca1234a1z5"}) |> GST.validate_gstin(:gstin)

      assert changeset.valid?
      assert get_change(changeset, :gstin) == "27AABCA1234A1Z5"
    end

    test "trims surrounding whitespace" do
      changeset = changeset(%{gstin: "  27AABCA1234A1Z5  "}) |> GST.validate_gstin(:gstin)

      assert changeset.valid?
    end

    test "rejects a malformed GSTIN" do
      changeset = changeset(%{gstin: "NOPE"}) |> GST.validate_gstin(:gstin)

      refute changeset.valid?
      assert %{gstin: ["is not a valid GSTIN"]} = errors(changeset)
    end

    test "takes a custom message" do
      changeset =
        changeset(%{gstin: "NOPE"}) |> GST.validate_gstin(:gstin, message: "must be a GSTIN")

      assert %{gstin: ["must be a GSTIN"]} = errors(changeset)
    end

    test "ignores a missing value" do
      assert changeset(%{}) |> GST.validate_gstin(:gstin) |> Map.get(:valid?)
    end
  end

  describe "validate_pan/3" do
    test "accepts a valid PAN and upcases it" do
      changeset = changeset(%{pan: "aabca1234a"}) |> GST.validate_pan(:pan)

      assert changeset.valid?
      assert get_change(changeset, :pan) == "AABCA1234A"
    end

    test "rejects the wrong shape" do
      refute changeset(%{pan: "AABCA1234"}) |> GST.validate_pan(:pan) |> Map.get(:valid?)
      refute changeset(%{pan: "1ABCA1234A"}) |> GST.validate_pan(:pan) |> Map.get(:valid?)
    end
  end

  describe "validate_gstin_matches_pan/3" do
    test "accepts a PAN that matches the GSTIN" do
      changeset =
        changeset(%{gstin: "27AABCA1234A1Z5", pan: "AABCA1234A"})
        |> GST.validate_gstin(:gstin)
        |> GST.validate_pan(:pan)
        |> GST.validate_gstin_matches_pan(:gstin, :pan)

      assert changeset.valid?
    end

    test "rejects a PAN that contradicts the GSTIN, naming the expected one" do
      changeset =
        changeset(%{gstin: "27AABCA1234A1Z5", pan: "ZZZZZ9999Z"})
        |> GST.validate_gstin(:gstin)
        |> GST.validate_pan(:pan)
        |> GST.validate_gstin_matches_pan(:gstin, :pan)

      refute changeset.valid?
      assert %{pan: ["does not match the PAN in the GSTIN (AABCA1234A)"]} = errors(changeset)
    end

    test "stays quiet when only one of the two is given" do
      assert changeset(%{gstin: "27AABCA1234A1Z5"})
             |> GST.validate_gstin_matches_pan(:gstin, :pan)
             |> Map.get(:valid?)

      assert changeset(%{pan: "AABCA1234A"})
             |> GST.validate_gstin_matches_pan(:gstin, :pan)
             |> Map.get(:valid?)
    end

    test "does not pile on when the GSTIN is itself malformed" do
      # validate_gstin/3 already reports it; a second complaint on the PAN
      # field would just be noise.
      changeset =
        changeset(%{gstin: "NOPE", pan: "AABCA1234A"})
        |> GST.validate_gstin_matches_pan(:gstin, :pan)

      assert changeset.valid?
    end
  end
end
