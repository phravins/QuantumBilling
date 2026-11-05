defmodule QuantumBilling.Accounts.Scope do
  @moduledoc """
  The caller's scope (user, business and role), passed as the first argument to contexts.
  """

  alias QuantumBilling.Accounts.User
  alias QuantumBilling.Businesses.Membership

  # `business` and `membership` are the business being worked in and the
  # caller's place in it; `businesses` is every one they may switch to.
  defstruct user: nil, business: nil, membership: nil, businesses: []

  @doc "A scope for `user`, or `nil` without one."
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc "The scope with the business `membership` belongs to chosen."
  def put_membership(%__MODULE__{} = scope, %Membership{business: business} = membership) do
    %{scope | business: business, membership: membership}
  end

  @doc """
  Whether the caller owns their current business. `false` when signed out or with no business.
  """
  def owner?(%__MODULE__{membership: membership}), do: Membership.owner?(membership)
  def owner?(_scope), do: false
end
