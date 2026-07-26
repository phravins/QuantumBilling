defmodule QuantumBillingWeb.EWayBillsComponents do
  @moduledoc """
  Building blocks for the e-way bill generation form: numbered sections, the
  labelled field wrapper, the transaction-type radio, and the rows of the live
  summary panel.

  `CoreComponents.input/1` renders its own label with daisyUI's `label` class
  and keeps its error markup private, so `field/1` wraps it: the label, the
  required marker and the error line all come from here, and the control itself
  is styled with the app form classes from `SharedComponents`.
  """
  use Phoenix.Component

  import QuantumBillingWeb.CoreComponents, only: [icon: 1, input: 1]
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
  Renders a labelled form control with its validation errors.

  Anything not consumed here is forwarded to `CoreComponents.input/1`, so
  `type`, `options`, `prompt`, `placeholder`, `readonly` and friends all work.
  """
  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :required, :boolean, default: false
  attr :hint, :string, default: nil
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(options prompt placeholder readonly disabled min step rows)

  def field(assigns) do
    assigns = assign(assigns, :errors, field_errors(assigns.field))

    ~H"""
    <div>
      <label for={@field.id} class="mb-1.5 block text-xs font-medium text-base-content/60">
        {@label}<span :if={@required} class="ml-0.5 text-error">*</span>
      </label>

      <.input
        field={@field}
        type={@type}
        class={[control_class(@type), @class, @errors != [] && form_error_class()]}
        error_class={form_error_class()}
        {@rest}
      />

      <p :if={@hint && @errors == []} class="mt-1 text-2xs text-base-content/45">{@hint}</p>

      <p :for={msg <- @errors} class="mt-1 flex items-center gap-1 text-2xs text-error">
        <.icon name="hero-exclamation-circle" class="size-3.5 shrink-0" />
        {msg}
      </p>
    </div>
    """
  end

  defp control_class("select"), do: form_select_class()
  defp control_class("textarea"), do: form_textarea_class()
  defp control_class(_type), do: form_input_class()

  # `input/1` only renders errors for fields the user has touched; mirror that
  # rule here so the two never disagree.
  defp field_errors(%Phoenix.HTML.FormField{} = field) do
    if Phoenix.Component.used_input?(field) do
      Enum.map(field.errors, &translate_error/1)
    else
      []
    end
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
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
      />
      {@label}
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
