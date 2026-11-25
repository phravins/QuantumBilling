defmodule QuantumBilling.ErrorMessages do
  @moduledoc """
  Turns the `reason` of an `{:error, reason}` into a sentence a person can read.

  Pages and the activity log show this text instead of `inspect(reason)`, so a
  user never sees an Elixir term. A reason this module does not know is logged
  in full and shown as a generic sentence.
  """

  require Logger

  alias QuantumBilling.EWayBills.NICClient
  alias QuantumBilling.Mail

  @generic "Something went wrong. Please try again."

  @known %{
    not_found: "That record no longer exists.",
    invoice_not_found: "That invoice no longer exists.",
    unauthorized: "You do not have permission to do that.",
    forbidden: "You do not have permission to do that.",
    cancelled: "This invoice is cancelled.",
    invoice_cancelled: "This invoice is cancelled.",
    already_cancelled: "This is already cancelled.",
    credited: "Credit notes already cover this invoice; nothing is owed.",
    invoice_credited: "Credit notes already cover this invoice; nothing is owed.",
    already_paid: "This invoice is already paid.",
    paid: "This invoice is paid. Issue a credit note instead.",
    partial_payment: "The amount is less than the invoice total.",
    irn_registered: "This invoice has a registered IRN. Cancel the e-invoice on the IRP first.",
    live_e_way_bill: "This invoice has a live e-way bill. Cancel the e-way bill first.",
    already_issued: "This invoice already carries a live e-way bill.",
    unsupported_currency: "Online payment is not available for this invoice's currency.",
    invalid_recipient: "There is no valid email address to send to.",
    not_configured: "This is not set up yet. Check Settings.",
    not_enabled: "This feature is turned off in Settings.",
    unavailable: "The service is not available right now. Try again shortly.",
    timeout: "The service did not answer in time. Try again.",
    no_renderer:
      "PDF export is not available on this server. Use your browser's Print option to save as PDF.",
    closed: "The connection closed before the work finished. Try again.",
    in_use: "It is still in use, so it cannot be removed.",
    not_in_bin: "That item is no longer in the Bin.",
    archived: "That template is archived.",
    expired: "This link has expired.",
    converted: "This quotation has already been turned into an invoice.",
    quotation_not_convertible: "This quotation cannot be turned into an invoice.",
    blocked: "This action is blocked right now.",
    rate_limited: "Too many attempts. Wait a minute and try again.",
    enoent: "The file could not be found.",
    too_large: "The file is too large.",
    transaction_aborted: "The change was not saved. Try again."
  }

  @doc """
  A sentence for `reason`:

    * a changeset gives its first error, as "Field message";
    * known atoms give a fixed sentence;
    * portal and mail failures use `NICClient.error_message/1` and
      `Mail.error_message/1`;
    * a string is already a sentence and is returned as is;
    * anything else gives a generic sentence, and the reason is logged.
  """
  def text(%Ecto.Changeset{} = changeset) do
    case first_error(changeset) do
      nil -> "The change could not be saved."
      {field, message} -> "#{humanize(field)} #{message}"
    end
  end

  def text(reason) when is_binary(reason) and reason != "", do: reason

  def text(reason) when is_atom(reason) and is_map_key(@known, reason),
    do: Map.fetch!(@known, reason)

  def text({:delivery_failed, message}) when is_binary(message), do: message
  def text({:refused, description}) when is_binary(description), do: description

  def text(%{__exception__: true} = exception) do
    Logger.error("[ErrorMessages] #{Exception.format(:error, exception)}")
    @generic
  end

  def text(reason) do
    case NICClient.error_message(reason) || mail_message(reason) do
      message when is_binary(message) ->
        message

      nil ->
        Logger.error("[ErrorMessages] unexpected error: #{inspect(reason)}")
        @generic
    end
  end

  @doc """
  The first message on a changeset, without the field name, or nil.
  """
  def first_message(%Ecto.Changeset{} = changeset) do
    case first_error(changeset) do
      {_field, message} -> message
      nil -> nil
    end
  end

  defp first_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&interpolate/1)
    |> flatten_errors()
    |> List.first()
  end

  defp interpolate({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn whole, key ->
      case Enum.find(opts, fn {name, _value} -> to_string(name) == key end) do
        {_name, value} when is_binary(value) or is_number(value) or is_atom(value) ->
          to_string(value)

        _other ->
          whole
      end
    end)
  end

  # Nested changesets give maps (or lists of maps) of their own errors.
  defp flatten_errors(errors) when is_map(errors) do
    Enum.flat_map(errors, fn
      {field, [message | _]} when is_binary(message) -> [{field, message}]
      {_field, nested} when is_map(nested) -> flatten_errors(nested)
      {_field, nested} when is_list(nested) -> Enum.flat_map(nested, &flatten_errors/1)
      _other -> []
    end)
  end

  defp flatten_errors(_other), do: []

  defp humanize(:base), do: "It"

  defp humanize(field) do
    QuantumBilling.Audit.Catalog.field_label(to_string(field))
  end

  # Mail.error_message/1 has no catch-all; only ask it about mail-shaped terms.
  defp mail_message(reason) do
    if mail_reason?(reason), do: Mail.error_message(reason)
  end

  defp mail_reason?({tag, _}) when tag in [:retries_exceeded, :auth_failed], do: true

  defp mail_reason?({tag, _, _})
       when tag in [:network_failure, :missing_requirement, :permanent_failure],
       do: true

  defp mail_reason?(reason) when reason in [:auth_failed, :no_relay, :econnrefused, :nxdomain],
    do: true

  defp mail_reason?(_reason), do: false
end
