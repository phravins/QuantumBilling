defmodule QuantumBillingWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use QuantumBillingWeb, :html

  embed_templates "error_html/*"

  def render("403.html", %{message: message}) when is_binary(message) do
    message
  end

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
