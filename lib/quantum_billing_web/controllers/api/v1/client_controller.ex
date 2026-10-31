defmodule QuantumBillingWeb.API.V1.ClientController do
  @moduledoc "`/api/v1/clients`: list, fetch and create, through `QuantumBilling.Clients`."
  use QuantumBillingWeb, :controller

  alias QuantumBilling.{Audit, Clients}
  alias QuantumBillingWeb.API.{ClientParams, Error, Idempotency, Pagination}
  alias QuantumBillingWeb.API.V1.ClientJSON
  alias QuantumBillingWeb.Plugs.RequireScope

  plug RequireScope, "clients:read" when action in [:index, :show]
  plug RequireScope, "clients:write" when action in [:create]

  def index(conn, params) do
    case Pagination.parse(params) do
      {:ok, page, per_page} ->
        opts =
          []
          |> put_filter(:status, params["status"])
          |> put_filter(:search, params["search"])
          |> then(&Pagination.context_opts(page, per_page, &1))

        json(conn, ClientJSON.index(%{page: opts |> Clients.page() |> Pagination.settle(page)}))

      {:error, fields} ->
        Error.send(conn, 400, :invalid_parameters, "The query parameters are invalid.", fields)
    end
  end

  def show(conn, %{"id" => id}) do
    case Clients.get_client(id) do
      nil -> Error.send(conn, 404, :not_found, "No such client.")
      client -> json(conn, ClientJSON.show(%{client: client}))
    end
  end

  def create(conn, _params) do
    Idempotency.run(conn, fn -> create_client(conn) end)
  end

  defp create_client(conn) do
    with {:ok, attrs} <- ClientParams.cast(conn.body_params),
         {:ok, client} <- Clients.create_client(attrs) do
      Audit.log_event(:client_created, "Client", client.id,
        api_key_id: conn.assigns.api_key.id,
        ip_address: conn.assigns.api_client_ip,
        details: %{"name" => client.name, "via" => "api"}
      )

      {201, ClientJSON.show(%{client: client})}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        validation_failed(Error.changeset_fields(changeset))

      {:error, fields} ->
        validation_failed(fields)
    end
  end

  defp validation_failed(fields) do
    {422,
     %{error: %{code: "validation_failed", message: "The client is invalid.", fields: fields}}}
  end

  defp put_filter(opts, _name, value) when value in [nil, ""], do: opts
  defp put_filter(opts, name, value) when is_binary(value), do: Keyword.put(opts, name, value)
  defp put_filter(opts, _name, _value), do: opts
end
