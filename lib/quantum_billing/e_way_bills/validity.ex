defmodule QuantumBilling.EWayBills.Validity do
  @moduledoc """
  How long an e-way bill is good for, under Rule 138(10) of the CGST Rules.

  One day for every 200 km of the approximate distance, or part thereof — 20 km
  for over-dimensional cargo and multimodal shipment involving a leg by ship —
  and "one day" is the period expiring at midnight of the day *following* the
  day the bill was generated. A 150 km run generated at 6pm is therefore good
  until the end of tomorrow, not until 6pm tomorrow.

  Both of the sums this replaces were wrong, in opposite directions. The portal
  path added `distance * 86400 / 100` seconds, which is a day per 100 km timed
  from the generation instant — half the statutory validity for a long haul,
  and expiring mid-afternoon rather than at midnight. The sandbox path added
  `(distance / 100 + 1)` whole days from the same instant, which is generous
  for short distances and still off the midnight boundary. A consignment whose
  bill the application says has expired while the law says it has not is a
  vehicle detained at a checkpost, so this is one rule in one place, tested.
  """

  @kilometres_per_day %{regular: 200, over_dimensional: 20}

  @doc """
  The last instant an e-way bill generated at `generated_at` stays valid.

  `cargo` is `:regular` (the default) or `:over_dimensional`.
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
