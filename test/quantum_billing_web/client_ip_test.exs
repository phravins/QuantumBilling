defmodule QuantumBillingWeb.ClientIPTest do
  use ExUnit.Case, async: false

  alias QuantumBillingWeb.ClientIP

  setup do
    previous = Application.get_env(:quantum_billing, :trusted_proxies, [])
    on_exit(fn -> Application.put_env(:quantum_billing, :trusted_proxies, previous) end)
    :ok
  end

  defp conn(remote_ip, forwarded_for \\ nil) do
    conn = %Plug.Conn{remote_ip: remote_ip, req_headers: []}

    case forwarded_for do
      nil -> conn
      value -> %{conn | req_headers: [{"x-forwarded-for", value}]}
    end
  end

  describe "client_ip/1 without trusted proxies" do
    test "uses the peer address" do
      assert ClientIP.client_ip(conn({203, 0, 113, 7})) == "203.0.113.7"
    end

    test "ignores x-forwarded-for, which anyone can send" do
      Application.put_env(:quantum_billing, :trusted_proxies, [])

      # The header claims to be an allowlisted address. Believing it would make
      # an IP allowlist meaningless.
      assert ClientIP.client_ip(conn({203, 0, 113, 7}, "127.0.0.1")) == "203.0.113.7"
    end
  end

  describe "client_ip/1 behind a declared proxy" do
    setup do
      Application.put_env(:quantum_billing, :trusted_proxies, ["10.0.0.0/8"])
      :ok
    end

    test "takes the address the proxy reports" do
      assert ClientIP.client_ip(conn({10, 0, 0, 5}, "198.51.100.4")) == "198.51.100.4"
    end

    test "reads the chain from the right, past other trusted proxies" do
      # A client that prepends its own entry cannot push itself to the front of
      # the chain, because the rightmost untrusted hop is the one taken.
      assert ClientIP.client_ip(conn({10, 0, 0, 5}, "1.2.3.4, 198.51.100.4, 10.0.0.9")) ==
               "198.51.100.4"
    end

    test "falls back to the peer when every hop is a trusted proxy" do
      assert ClientIP.client_ip(conn({10, 0, 0, 5}, "10.0.0.9")) == "10.0.0.5"
    end

    test "a connection from somewhere else is not believed" do
      assert ClientIP.client_ip(conn({203, 0, 113, 7}, "198.51.100.4")) == "203.0.113.7"
    end
  end

  describe "allowed?/2" do
    test "matches single addresses" do
      assert ClientIP.allowed?("192.168.1.10", ["192.168.1.10", "10.0.0.1"])
      refute ClientIP.allowed?("192.168.1.11", ["192.168.1.10"])
    end

    test "matches IPv4 CIDR blocks" do
      assert ClientIP.allowed?("10.1.2.3", ["10.0.0.0/8"])
      assert ClientIP.allowed?("192.168.4.200", ["192.168.4.0/24"])
      refute ClientIP.allowed?("192.168.5.1", ["192.168.4.0/24"])
    end

    test "matches IPv6 addresses and blocks" do
      assert ClientIP.allowed?("2001:db8::1", ["2001:db8::/32"])
      refute ClientIP.allowed?("2001:dead::1", ["2001:db8::/32"])
      assert ClientIP.allowed?("::1", ["::1"])
    end

    test "treats an IPv4-mapped IPv6 peer as the IPv4 address it is" do
      # What a dual-stack listener reports for an IPv4 client. Without this an
      # allowlist of plain IPv4 addresses would never match.
      assert ClientIP.allowed?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}, ["127.0.0.1"])
    end

    test "a malformed entry matches nothing rather than everything" do
      refute ClientIP.allowed?("10.0.0.1", ["not-an-ip"])
      refute ClientIP.allowed?("10.0.0.1", ["10.0.0.0/999"])
      refute ClientIP.allowed?("10.0.0.1", ["10.0.0.0/8/16"])
      refute ClientIP.allowed?("10.0.0.1", [""])
    end

    test "does not match across IP versions" do
      refute ClientIP.allowed?("127.0.0.1", ["::1"])
      refute ClientIP.allowed?("::1", ["0.0.0.0/0"])
    end

    test "an empty allowlist matches nothing" do
      refute ClientIP.allowed?("10.0.0.1", [])
    end
  end
end
