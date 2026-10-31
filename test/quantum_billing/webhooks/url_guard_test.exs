defmodule QuantumBilling.Webhooks.UrlGuardTest do
  @moduledoc """
  The ranges this server refuses to open a connection to.

  Asserted against `public?/1` directly wherever DNS would otherwise be
  involved: the substance here is the range list, and routing it through a
  resolver would be testing the resolver.
  """
  use ExUnit.Case, async: true

  alias QuantumBilling.Webhooks.UrlGuard

  describe "public?/1" do
    test "refuses loopback" do
      refute UrlGuard.public?({127, 0, 0, 1})
      refute UrlGuard.public?({127, 255, 255, 254})
      refute UrlGuard.public?({0, 0, 0, 0, 0, 0, 0, 1})
    end

    test "refuses the link-local range every cloud metadata service lives in" do
      # The one that matters most: a request here on EC2, GCP or Azure reaches
      # the instance's own credentials endpoint.
      refute UrlGuard.public?({169, 254, 169, 254})
      refute UrlGuard.public?({169, 254, 0, 1})
    end

    test "refuses the RFC 1918 private ranges" do
      refute UrlGuard.public?({10, 0, 0, 1})
      refute UrlGuard.public?({192, 168, 1, 1})
      refute UrlGuard.public?({172, 16, 0, 1})
      refute UrlGuard.public?({172, 31, 255, 254})
    end

    test "allows the addresses either side of 172.16/12, which is easy to get wrong" do
      assert UrlGuard.public?({172, 15, 255, 255})
      assert UrlGuard.public?({172, 32, 0, 1})
    end

    test "refuses carrier-grade NAT, 0.0.0.0/8 and multicast" do
      refute UrlGuard.public?({100, 64, 0, 1})
      refute UrlGuard.public?({100, 127, 255, 254})
      refute UrlGuard.public?({0, 0, 0, 0})
      refute UrlGuard.public?({224, 0, 0, 1})
      refute UrlGuard.public?({255, 255, 255, 255})
    end

    test "allows the addresses either side of 100.64/10" do
      assert UrlGuard.public?({100, 63, 255, 255})
      assert UrlGuard.public?({100, 128, 0, 1})
    end

    test "refuses IPv6 unique-local and link-local" do
      refute UrlGuard.public?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
      refute UrlGuard.public?({0xFD00, 0, 0, 0, 0, 0, 0, 1})
      refute UrlGuard.public?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
    end

    test "judges an IPv4-mapped IPv6 address on what it maps to" do
      # ::ffff:127.0.0.1 — without this the whole guard is one prefix away
      # from being bypassed.
      refute UrlGuard.public?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
      # ::ffff:169.254.169.254
      refute UrlGuard.public?({0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE})
      # ::ffff:10.0.0.1
      refute UrlGuard.public?({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0001})
      # ::ffff:93.184.216.34, a public address
      assert UrlGuard.public?({0, 0, 0, 0, 0, 0xFFFF, 0x5DB8, 0xD822})
    end

    test "allows ordinary public addresses" do
      assert UrlGuard.public?({93, 184, 216, 34})
      assert UrlGuard.public?({8, 8, 8, 8})
      assert UrlGuard.public?({0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888})
    end

    test "refuses anything that is not an address" do
      refute UrlGuard.public?("127.0.0.1")
      refute UrlGuard.public?(nil)
    end
  end

  describe "check/1" do
    test "refuses a literal private address without needing DNS" do
      for url <- [
            "http://169.254.169.254/latest/meta-data/",
            "http://127.0.0.1:5432/",
            "http://10.1.2.3/hooks",
            "http://[::1]:4000/hooks"
          ] do
        assert {:error, message} = UrlGuard.check(url), "#{url} was allowed"
        assert message =~ "inside the server's own network"
      end
    end

    test "refuses names that only mean something inside a network" do
      for url <- [
            "http://localhost/hooks",
            "http://metadata.google.internal/x",
            "http://db.local/hooks",
            "http://orders.internal/hooks"
          ] do
        assert {:error, _message} = UrlGuard.check(url), "#{url} was allowed"
      end
    end

    test "refuses a scheme this server will not speak" do
      for url <- ["ftp://example.com/x", "file:///etc/passwd", "gopher://example.com/"] do
        assert {:error, message} = UrlGuard.check(url), "#{url} was allowed"
        assert message =~ "http"
      end
    end

    test "refuses what is not a URL at all" do
      assert {:error, _} = UrlGuard.check("not a url")
      assert {:error, _} = UrlGuard.check("https://")
      assert {:error, _} = UrlGuard.check("")
      assert {:error, _} = UrlGuard.check(nil)
      assert {:error, _} = UrlGuard.check(42)
    end

    test "allows a name it cannot resolve" do
      # Unresolvable names pass here; the worker re-checks live DNS before connecting.
      assert :ok = UrlGuard.check("https://hooks.example.test/incoming")
    end
  end

  describe "pin/1" do
    alias QuantumBilling.FakeDNS

    test "rewrites the URL to the checked address and keeps the name for Host, SNI and TLS" do
      assert {:ok, pinned, options} = UrlGuard.pin("https://hooks.example.test:8443/in?x=1")

      assert pinned == "https://203.0.113.10:8443/in?x=1"
      assert options == [connect_options: [hostname: "hooks.example.test"]]
    end

    # The rebinding attack: the name is public when it is saved and private by
    # the time anything is sent. pin/1 resolves at send time and connects to
    # what it resolved, so there is no later lookup to win.
    test "refuses a name that now resolves inside the network" do
      FakeDNS.put("rebound.example.test", [{127, 0, 0, 1}])

      assert {:error, message} = UrlGuard.pin("https://rebound.example.test/in")
      assert message =~ "inside"
    end

    test "refuses a name with any private address among public ones" do
      FakeDNS.put("mixed.example.test", [FakeDNS.public_address(), {10, 0, 0, 7}])

      assert {:error, _} = UrlGuard.pin("https://mixed.example.test/in")
    end

    test "refuses a name that does not resolve, since there is nothing to pin" do
      FakeDNS.put("gone.example.test", [])

      assert {:error, "could not be resolved"} = UrlGuard.pin("https://gone.example.test/in")
    end

    test "brackets an IPv6 address" do
      FakeDNS.put("v6.example.test", [{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}])

      assert {:ok, "https://[2001:db8::1]/in", _} = UrlGuard.pin("https://v6.example.test/in")
    end
  end
end
