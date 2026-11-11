defmodule QuantumBilling.Accounts.Scope do
  @moduledoc """
  The caller's scope (user, business and role), passed as the first argument to contexts.
  """

  alias QuantumBilling.Accounts.User
  alias QuantumBilling.Businesses.Membership

  # `business` and `membership` are the business being worked in and the
  # caller's place in it; `businesses` is every one they may switch to.
  # `tax_regime` is that business's, read once when it is chosen.
  defstruct user: nil, business: nil, membership: nil, businesses: [], tax_regime: nil

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

  @doc "The scope with the business's tax regime (`\"gst\"` or `\"vat\"`) recorded."
  def put_tax_regime(%__MODULE__{} = scope, regime) when regime in ["gst", "vat"],
    do: %{scope | tax_regime: regime}

  @doc "Whether the current business charges VAT, so the India GST features are off."
  def vat?(%__MODULE__{tax_regime: "vat"}), do: true
  def vat?(_scope), do: false
end
