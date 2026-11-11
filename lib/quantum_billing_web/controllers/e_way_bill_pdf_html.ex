defmodule QuantumBillingWeb.EWayBillPdfHTML do
  @moduledoc """
  The printable e-way bill page for `EWayBillPdfController`: the whole
  document from `EWayBillDoc.Document`, outside the app layout.
  """
  alias QuantumBillingWeb.EWayBillDoc.Document

  def show(assigns), do: Document.page(assigns)
end
