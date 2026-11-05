defmodule QuantumBilling.EWayBills.Validity do
  @moduledoc """
  E-way bill validity under Rule 138(10) of the CGST Rules.

  One day per 200 km or part (20 km for over-dimensional cargo). Each day ends
  at midnight of the day after generation, so a 150 km bill made at 6pm is
  valid until the end of tomorrow.
  """

  @kilometres_per_day %{regular: 200, over_dimensional: 20}

  @doc """
  The last valid instant of a bill generated at `generated_at`. `cargo` is `:regular` (default) or `:over_dimensional`.
  """
  def valid_until(generated_at, distance_km, cargo \\ :regular)

  def valid_until(%NaiveDateTime{} = generated_at, distance_km, cargo) do
    generated_at
    |> NaiveDateTime.to_date()
    |> Date.add(days(distance_km, cargo))
    |> NaiveDateTime.new!(~T[23:59:59])
  end

  def valid_until(%DateTime{} = generated_at, distance_km, cargo) do
    generated_at
    |> DateTime.to_naive()
    |> valid_until(distance_km, cargo)
  end

  @doc """
  How many days of validity a distance earns: one per 200 km or part of one,
  and never fewer than one.
  """
  def days(distance_km, cargo \\ :regular)

  def days(distance_km, cargo) when is_integer(distance_km) and distance_km > 0 do
    max(1, ceil(distance_km / kilometres_per_day(cargo)))
  end

  # No distance recorded: the one-day minimum.
  def days(_unknown_distance, _cargo), do: 1

  @doc "Kilometres that earn one day of validity, by cargo type."
  def kilometres_per_day(cargo), do: Map.get(@kilometres_per_day, cargo, 200)
end
