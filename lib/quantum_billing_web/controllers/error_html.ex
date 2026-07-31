defmodule QuantumBillingWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs.
  """
  use QuantumBillingWeb, :html

  # Branded pages for the two statuses users actually see. Each template is a
  # complete HTML document, so it renders the same whether it arrives here via
  # the catch-all route or via render_errors (configured `layout: false`).
  embed_templates "error_html/*"

  # Every other status falls back to a plain text page based on the template
  # name. For example, "403.html" becomes "Forbidden".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
