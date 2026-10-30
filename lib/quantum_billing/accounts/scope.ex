defmodule QuantumBilling.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `QuantumBilling.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use in authorization checks,
  or to ensure specific code paths can only be accessed for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias QuantumBilling.Accounts.User
  alias QuantumBilling.Businesses.Membership

  # `business` and `membership` are the business being worked in and the
  # caller's place in it; `businesses` is every one they may switch to.
  defstruct user: nil, business: nil, membership: nil, businesses: []

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc "The scope with the business `membership` belongs to chosen."
  def put_membership(%__MODULE__{} = scope, %Membership{business: business} = membership) do
    %{scope | business: business, membership: membership}
  end

  @doc """
  Whether the caller owns the business they are working in.

  Asked of the scope rather than reached through to the membership, so an
  authorization check reads the same wherever it appears, and a signed-out
  caller or one who has not chosen a business answers `false` rather than
  raising.
  """
  def owner?(%__MODULE__{membership: membership}), do: Membership.owner?(membership)
  def owner?(_scope), do: false
end
