defmodule QuantumBillingWeb.API.V1.QuotationController do
  @moduledoc """
  `/api/v1/quotations`. Everything goes through `Quotations`, so numbering,
  the status rules, audit rows and webhooks match the screens. Binned
  quotations are not found.
  """
  use QuantumBillingWeb, :controller

  alias QuantumBilling.{Clients, Invoices, Quotations}
  alias QuantumBilling.Settings
  alias QuantumBilling.Settings.Organization
  alias QuantumBillingWeb.API.{ActionParams, Error, Idempotency, Pagination, QuotationParams}
  alias QuantumBillingWeb.API.V1.QuotationJSON
  alias QuantumBillingWeb.Plugs.RequireScope

  plug RequireScope, "quotations:read" when action in [:index, :show]
  plug RequireScope, "quotations:write" when action in [:create, :send_email, :accept, :decline]

  @statuses ~w(Draft Sent Accepted Declined Expired)

  def index(conn, params) do
    with {:ok, page, per_page} <- Pagination.parse(params),
         {:ok, opts} <- filters(params) do
      result =
        page
        |> Pagination.context_opts(per_page, opts)
        |> Quotations.page()
        |> Pagination.settle(page)

      json(conn, QuotationJSON.index(%{page: result, api_key: conn.assigns.api_key}))
    else
      {:error, fields} ->
        Error.send(conn, 400, :invalid_parameters, "The query parameters are invalid.", fields)
    end
  end

  def show(conn, %{"id" => id}) do
    case Quotations.get_quotation(id) do
      nil ->
        Error.send(conn, 404, :not_found, "No such quotation.")

      quotation ->
        json(conn, QuotationJSON.show(%{quotation: quotation, api_key: conn.assigns.api_key}))
    end
  end

  def create(conn, _params) do
    Idempotency.run(conn, fn -> create_quotation(conn) end)
  end

  defp create_quotation(conn) do
    organization = Settings.get_organization()
    regime = Organization.tax_regime(organization)

    currency = Organization.currency_code(organization)

    with {:ok, client_id, attrs} <- QuotationParams.cast(conn.body_params, regime, currency),
         {:client, %Clients.Client{} = client} <- {:client, Clients.get_client(client_id)},
         attrs = attrs |> with_dates(organization) |> Map.merge(Invoices.client_snapshot(client)),
         {:ok, quotation} <- Quotations.create_quotation(actor(conn), attrs) do
      {201, QuotationJSON.show(%{quotation: quotation, api_key: conn.assigns.api_key})}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        validation_failed(Error.changeset_fields(changeset))

      {:error, fields} when is_map(fields) ->
        validation_failed(fields)

      {:client, nil} ->
        validation_failed(%{"client_id" => ["must be the id of an existing client"]})

      {:error, _reason} ->
        {500,
         %{
           error: %{code: "internal_error", message: "The quotation could not be created. Retry."}
         }}
    end
  end

  @doc """
  `POST /quotations/:id/send`: emails the quotation, PDF attached, with the
  client link. `to` defaults to the client's email. Answers 202 once queued;
  a Draft becomes Sent.
  """
  def send_email(conn, %{"id" => id}) do
    Idempotency.run(conn, fn ->
      with {:quotation, %{} = quotation} <- {:quotation, Quotations.get_quotation(id)},
           {:ok, to} <- ActionParams.quotation_email(conn.body_params),
           {:ok, sent, _delivery} <-
             Quotations.send_email(actor(conn), quotation, to || quotation.client_email) do
        {202, QuotationJSON.show(%{quotation: sent, api_key: conn.assigns.api_key})}
      else
        {:quotation, nil} ->
          not_found_body()

        {:error, :invalid_recipient} ->
          validation_failed(%{
            "to" => ["must be one email address; the client has none on this quotation"]
          })

        {:error, :expired} ->
          conflict(:expired, "This quotation has expired. Extend valid_until first.")

        {:error, fields} when is_map(fields) ->
          validation_failed(fields)

        {:error, _reason} ->
          {500, %{error: %{code: "internal_error", message: "Could not queue the email. Retry."}}}
      end
    end)
  end

  @doc "`POST /quotations/:id/accept`: Draft or Sent, and not expired, to Accepted."
  def accept(conn, %{"id" => id}), do: transition(conn, id, &Quotations.accept/2)

  @doc "`POST /quotations/:id/decline`: Draft or Sent to Declined."
  def decline(conn, %{"id" => id}), do: transition(conn, id, &Quotations.decline/2)

  defp transition(conn, id, fun) do
    Idempotency.run(conn, fn ->
      with {:quotation, %{} = quotation} <- {:quotation, Quotations.get_quotation(id)},
           :ok <- ActionParams.empty(conn.body_params),
           {:ok, updated} <- fun.(actor(conn), quotation) do
        {200, QuotationJSON.show(%{quotation: updated, api_key: conn.assigns.api_key})}
      else
        {:quotation, nil} ->
          not_found_body()

        {:error, :not_found} ->
          not_found_body()

        {:error, :invalid_transition} ->
          conflict(
            :invalid_transition,
            "Not possible from this quotation's status (an expired one needs a later valid_until)."
          )

        {:error, :stale_revision} ->
          conflict(
            :stale_revision,
            "The quotation changed while the request was being processed. Fetch it again before answering."
          )

        {:error, fields} when is_map(fields) ->
          validation_failed(fields)

        {:error, _reason} ->
          {500, %{error: %{code: "internal_error", message: "The change was not saved. Retry."}}}
      end
    end)
  end

  # Today and the business's validity period, when left out. A malformed
  # quotation_date is left for the changeset to report.
  defp with_dates(attrs, organization) do
    attrs = Map.put_new(attrs, "quotation_date", Date.to_iso8601(Quotations.today()))

    case {Map.has_key?(attrs, "valid_until"),
          Date.from_iso8601(to_string(attrs["quotation_date"]))} do
      {false, {:ok, date}} ->
        valid_until = Quotations.default_valid_until(organization, date)
        Map.put(attrs, "valid_until", Date.to_iso8601(valid_until))

      _given_or_invalid ->
        attrs
    end
  end

  defp filters(params) do
    opts = [count: false]

    opts =
      case params["search"] do
        search when is_binary(search) and search != "" -> Keyword.put(opts, :search, search)
        _none -> opts
      end

    case params["status"] do
      nil -> {:ok, opts}
      "" -> {:ok, opts}
      status when status in @statuses -> {:ok, Keyword.put(opts, :status, status)}
      _other -> {:error, %{"status" => ["must be one of #{Enum.join(@statuses, ", ")}"]}}
    end
  end

  defp actor(conn),
    do: [api_key_id: conn.assigns.api_key.id, ip_address: conn.assigns.api_client_ip, via: "api"]

  defp conflict(code, message), do: {409, %{error: %{code: to_string(code), message: message}}}

  defp not_found_body, do: {404, %{error: %{code: "not_found", message: "No such quotation."}}}

  defp validation_failed(fields) do
    {422,
     %{error: %{code: "validation_failed", message: "The quotation is invalid.", fields: fields}}}
  end
end
