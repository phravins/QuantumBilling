defmodule QuantumBilling.SecurityTest do
  @moduledoc """
  The properties that stop this application handing out access it should not:
  unguessable portal tokens, credentials that are unreadable in the database,
  and a rate limiter that actually counts parallel attempts.
  """
  use QuantumBilling.DataCase, async: false

  alias QuantumBilling.Encrypted.Secret
  alias QuantumBilling.Invoices.Invoice
  alias QuantumBilling.RateLimiter
  alias QuantumBilling.Settings

  describe "public invoice tokens" do
    test "are long, random and unrelated to each other" do
      tokens = for _ <- 1..200, do: Invoice.generate_public_token()

      assert length(Enum.uniq(tokens)) == 200

      for token <- tokens do
        assert String.starts_with?(token, "inv_")
        # 24 bytes, base64url: 192 bits of entropy, versus the 24 decimal
        # digits from a predictable generator that this replaced.
        assert String.length(token) >= 32
      end
    end

    test "an invoice gets one automatically and a caller cannot choose it" do
      attrs = %{
        "invoice_date" => "2026-03-01",
        "place_of_supply" => "Maharashtra",
        "client_name" => "Acme Corp",
        "public_token" => "inv_chosen-by-the-attacker",
        "items" => %{
          "0" => %{
            "description" => "Service",
            "quantity" => "1",
            "rate" => "1000",
            "tax_rate" => "18"
          }
        }
      }

      changeset = Invoice.changeset(%Invoice{}, attrs)
      token = Ecto.Changeset.get_field(changeset, :public_token)

      assert is_binary(token)
      refute token == "inv_chosen-by-the-attacker"
    end
  end

  describe "stored credentials" do
    test "round-trip through the encrypted type" do
      {:ok, stored} = Secret.dump("whsec_live_abcdef")
      assert {:ok, "whsec_live_abcdef"} = Secret.load(stored)
      refute stored =~ "whsec_live"
    end

    test "a blank secret is stored as absent rather than as empty ciphertext" do
      assert {:ok, nil} = Secret.dump("")
      assert {:ok, nil} = Secret.dump(nil)
    end

    test "a tampered value fails instead of decrypting to something else" do
      {:ok, stored} = Secret.dump("original")
      <<head::binary-size(32), byte, rest::binary>> = stored

      assert Secret.load(head <> <<Bitwise.bxor(byte, 1)>> <> rest) == :error
    end

    test "a two-factor secret cannot be read as an integration credential" do
      # Different additional authenticated data, so a value moved between
      # columns fails its tag check rather than being decrypted by the wrong
      # type.
      {:ok, totp} = QuantumBilling.Encrypted.Binary.dump("totp-secret")

      assert Secret.load(totp) == :error
    end

    test "every credential column is unreadable in the database" do
      {:ok, _organization} =
        Settings.update_section(
          Settings.get_organization(),
          %{
            "razorpay_key_id" => "rzp_live_visible",
            "razorpay_key_secret" => "rzp_secret_hidden",
            "irp_username" => "irp_visible",
            "irp_password" => "irp_secret_hidden",
            "webhook_url" => "https://example.test/hooks",
            "webhook_secret" => "whsec_hidden"
          },
          :integrations
        )

      %{rows: [row]} =
        Repo.query!(
          """
          SELECT razorpay_key_id, razorpay_key_secret, irp_username, irp_password,
                 webhook_url, webhook_secret
          FROM organization_settings LIMIT 1
          """,
          []
        )

      [key_id, key_secret, irp_username, irp_password, webhook_url, webhook_secret] = row

      # Configuration stays readable; credentials do not.
      assert key_id == "rzp_live_visible"
      assert irp_username == "irp_visible"
      assert webhook_url == "https://example.test/hooks"

      refute key_secret =~ "rzp_secret_hidden"
      refute irp_password =~ "irp_secret_hidden"
      refute webhook_secret =~ "whsec_hidden"

      organization = Settings.get_organization()
      assert organization.razorpay_key_secret == "rzp_secret_hidden"
      assert organization.webhook_secret == "whsec_hidden"
    end
  end

  describe "rate limiting" do
    setup do
      RateLimiter.clear_all()
      on_exit(&RateLimiter.clear_all/0)
      :ok
    end

    test "counts every attempt, including simultaneous ones" do
      # The old read-then-write let parallel attempts read the same count and
      # write the same increment, so a burst counted as one — which is exactly
      # the shape of a credential-stuffing script.
      key = {:login, "burst@example.com"}

      results =
        1..50
        |> Task.async_stream(fn _ -> RateLimiter.hit(key, 10, 60) end,
          max_concurrency: 25,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      allowed = Enum.count(results, &match?({:ok, _}, &1))
      limited = Enum.count(results, &match?({:error, :rate_limited, _}, &1))

      assert allowed == 10
      assert limited == 40
    end

    test "reports how long to wait, and forgets once the window passes" do
      key = {:login, "waiter@example.com"}

      assert {:ok, 0} = RateLimiter.hit(key, 1, 60)
      assert {:error, :rate_limited, retry_after} = RateLimiter.hit(key, 1, 60)
      assert retry_after > 0

      assert RateLimiter.limited?(key, 1)

      RateLimiter.reset(key)
      refute RateLimiter.limited?(key, 1)
      assert {:ok, 0} = RateLimiter.hit(key, 1, 60)
    end

    test "a window that has already closed starts a fresh count" do
      key = {:login, "expired@example.com"}

      # A window of zero seconds is already over by the time it is read.
      assert {:ok, 0} = RateLimiter.hit(key, 1, 0)
      assert {:ok, 0} = RateLimiter.hit(key, 1, 0)
      refute RateLimiter.limited?(key, 1)
    end

    test "different keys are counted separately" do
      assert {:ok, 0} = RateLimiter.hit({:login, "a@example.com"}, 1, 60)
      assert {:ok, 0} = RateLimiter.hit({:login, "b@example.com"}, 1, 60)
    end
  end
end
