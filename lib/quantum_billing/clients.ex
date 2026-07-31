defmodule QuantumBilling.Clients do
  @moduledoc """
  Customers a tenant invoices.
  """

  import Ecto.Query, warn: false

  alias QuantumBilling.Clients.Client
  alias QuantumBilling.Events
  alias QuantumBilling.Repo

  @doc """
  Subscribes the caller to client changes.

  See `QuantumBilling.Events` for the messages and why the topic is
  organisation-wide rather than per user.
  """
  def subscribe, do: Events.subscribe(Events.clients_topic())

  @doc """
  Every client, alphabetically.
  """
  def list_clients do
    Repo.all(from c in Client, order_by: [asc: c.name])
  end

  @doc """
  Fetches a client by id, raising when it does not exist.
  """
  def get_client!(id), do: Repo.get!(Client, id)

  @doc """
  Builds a changeset for a client form.
  """
  def change_client(%Client{} = client \\ %Client{}, attrs \\ %{}) do
    Client.changeset(client, attrs)
  end

  @doc """
  Creates a client.
  """
  def create_client(attrs) do
    %Client{}
    |> Client.changeset(attrs)
    |> Repo.insert()
    |> announce(:client_created)
  end

  @doc """
  Updates a client.
  """
  def update_client(%Client{} = client, attrs) do
    client
    |> Client.changeset(attrs)
    |> Repo.update()
    |> announce(:client_updated)
  end

  # Only a successful write is announced, and the notification never changes
  # the result the caller gets back.
  defp announce({:ok, client} = result, event) do
    Events.broadcast(Events.clients_topic(), {event, client})
    result
  end

  defp announce({:error, _changeset} = result, _event), do: result

  @doc """
  Whether a client of this type must supply a GSTIN.

  The form asks this to decide whether to show the required marker, so the
  asterisk and the changeset can never disagree.
  """
  defdelegate gstin_required?(client_type), to: Client

  defdelegate client_types(), to: Client
  defdelegate business_types(), to: Client
  defdelegate categories(), to: Client
  defdelegate country_codes(), to: Client
  defdelegate statuses(), to: Client
end
