defmodule QuantumBillingWeb.EWayBillsComponents do
  @moduledoc """
  Building blocks specific to the e-way bill generation form: numbered
  sections, the transaction-type radio, and the rows of the live summary panel.

  The labelled `field/1` used throughout the form now lives in
  `QuantumBillingWeb.SharedComponents`, since the Settings page needs it too.
  It is auto-imported into every view, so the form picks it up without an
  import here.
  """
  use Phoenix.Component

  import QuantumBillingWeb.SharedComponents

  @doc """
  Renders one numbered form section as a card.

  ## Examples

      <.form_section step="1" title="Transaction Details">…</.form_section>
  """
  attr :step, :string, required: true
  attr :title, :string, required: true
  attr :class, :any, default: nil

  slot :inner_block, required: true

  def form_section(assigns) do
    ~H"""
    <.card padding="p-5" class={@class}>
      <div class="mb-4 flex items-center gap-2.5">
        <span class="flex size-5 shrink-0 items-center justify-center rounded-full bg-primary text-2xs font-semibold text-primary-content">
          {@step}
        </span>
        
        <h2 class="text-sm font-semibold tracking-tight">{@title}</h2>
      </div>
       {render_slot(@inner_block)}
    </.card>
    """
  end

  @doc """
  Renders one option of the transaction-type radio group.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true

  def radio_option(assigns) do
    ~H"""
    <label class="inline-flex cursor-pointer items-center gap-2 text-sm">
      <input
        type="radio"
        name={@field.name}
        id={"#{@field.id}_#{slug(@value)}"}
        value={@value}
        checked={to_string(@field.value) == @value}
        class="size-4 accent-base-content"
      /> {@label}
    </label>
    """
  end

  defp slug(value), do: value |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")

  @doc """
  Renders a label/value pair in the summary panel. `emphasis` styles the
  closing total line.
  """
  attr :label, :string, required: true
  attr :value, :string, default: nil
  attr :emphasis, :boolean, default: false

  slot :inner_block

  def summary_row(assigns) do
    ~H"""
    <div class={[
      "flex items-start justify-between gap-4",
      @emphasis && "rounded-field bg-base-200 px-3 py-2.5"
    ]}>
      <span class={[
        "text-xs",
        if(@emphasis, do: "font-semibold text-base-content", else: "text-base-content/60")
      ]}>
        {@label}
      </span>
      
      <span class={[
        "text-right text-xs",
        if(@emphasis, do: "text-sm font-semibold tracking-tight", else: "font-medium")
      ]}>
        {render_slot(@inner_block) || blank(@value)}
      </span>
    </div>
    """
  end

  defp blank(nil), do: "—"
  defp blank(""), do: "—"
  defp blank(value), do: value
end
