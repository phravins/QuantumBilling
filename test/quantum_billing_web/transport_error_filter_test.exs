defmodule QuantumBillingWeb.TransportErrorFilterTest do
  @moduledoc """
  The filter's whole job is to be narrow: drop the noise, keep everything that
  could indicate a real fault. Most of these tests are about what it must
  *not* swallow.
  """
  use ExUnit.Case, async: true

  alias QuantumBillingWeb.TransportErrorFilter

  # The shape OTP actually emits, captured from a real labelled GenServer
  # terminating rather than written from memory.
  defp connection_report(reason, overrides \\ %{}) do
    report =
      Map.merge(
        %{
          label: {:gen_server, :terminate},
          name: self(),
          reason: reason,
          process_label:
            {:thousand_island, :connection, {Bandit.DelegatingHandler, {{127, 0, 0, 1}, 49_390}}},
          last_message: {:tcp_error, :erlang.list_to_port(~c"#Port<0.138>"), reason},
          state: :some_state,
          log: [],
          client_info: nil
        },
        overrides
      )

    %{msg: {:report, report}, meta: %{}, level: :error}
  end

  describe "drops peer aborts" do
    test "the exact report from the reported log" do
      assert TransportErrorFilter.filter(connection_report(:econnaborted), []) == :stop
    end

    test "every transport reason it claims to cover" do
      for reason <- TransportErrorFilter.transport_reasons() do
        assert TransportErrorFilter.filter(connection_report(reason), []) == :stop,
               "expected #{inspect(reason)} to be dropped"
      end
    end
  end

  describe "keeps anything that could be a real fault" do
    test "a genuine exception inside a connection process" do
      # A real bug carries {exception, stacktrace}, not a bare atom — which is
      # exactly what separates it from a peer hanging up.
      reason = {%RuntimeError{message: "boom"}, [{Foo, :bar, 1, []}]}

      assert TransportErrorFilter.filter(connection_report(reason), []) == :ignore
    end

    test "an exit reason that is an atom but not a transport error" do
      assert TransportErrorFilter.filter(connection_report(:badarg), []) == :ignore
      assert TransportErrorFilter.filter(connection_report(:timeout), []) == :ignore
    end

    test "the same transport reason from a process that is not a connection" do
      # Some other GenServer dying with :closed is not this filter's business.
      report = connection_report(:econnaborted, %{process_label: nil})

      assert TransportErrorFilter.filter(report, []) == :ignore
    end

    test "a ThousandIsland process that is not a connection" do
      report =
        connection_report(:econnaborted, %{process_label: {:thousand_island, :acceptor, {}}})

      assert TransportErrorFilter.filter(report, []) == :ignore
    end

    test "a report that is not a gen_server terminate" do
      report = connection_report(:econnaborted, %{label: {:proc_lib, :crash}})

      assert TransportErrorFilter.filter(report, []) == :ignore
    end
  end

  describe "never raises" do
    # A logger filter that raises takes the handler down with it, so the
    # catch-all matters more than it looks.
    test "on a plain string message" do
      assert TransportErrorFilter.filter(%{msg: {:string, "hello"}, meta: %{}}, []) == :ignore
    end

    test "on a format-style message" do
      assert TransportErrorFilter.filter(%{msg: {~c"~p", [:x]}, meta: %{}}, []) == :ignore
    end

    test "on a report that is a keyword list rather than a map" do
      assert TransportErrorFilter.filter(%{msg: {:report, [a: 1]}, meta: %{}}, []) == :ignore
    end

    test "on an event missing the keys it looks for" do
      assert TransportErrorFilter.filter(%{msg: {:report, %{}}, meta: %{}}, []) == :ignore
      assert TransportErrorFilter.filter(%{}, []) == :ignore
    end
  end

  describe "installed at boot" do
    test "the primary filter is registered" do
      filters = :logger.get_primary_config().filters

      assert Keyword.has_key?(filters, :quantum_billing_transport_errors),
             "expected Application.start/2 to have installed the filter"
    end
  end
end
