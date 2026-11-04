defmodule QuantumBillingWeb.Illustrations do
  @moduledoc """
  The flat illustrations on the focus screens: the company picker, the
  "you're in" screen after choosing a company, and first-sign-in onboarding.

  Inline SVG, so there is no file to fetch, nothing for the Content Security
  Policy to allow. Drawn in the app's own ink and greys (`base-content` tints
  on `base-100`/`base-200`), so they sit in the plain theme and follow light
  and dark mode with it. Every colour is a literal class so Tailwind emits it.

  Decoration only: each SVG is `aria-hidden`, and the screen around it says in
  words whatever the picture shows.
  """
  use Phoenix.Component

  @stroke "stroke-base-content/80"
  @backdrop "fill-base-content/5"
  @ground "fill-base-content/8"

  @doc """
  A company: one of five buildings, so cards side by side do not look alike.

  `variant` picks the building (any integer; it wraps), `tone` the colour of
  its walls (a literal `fill-*` class from the caller).
  """
  attr :variant, :integer, default: 0
  attr :tone, :string, default: "fill-base-200"
  attr :class, :any, default: "h-28 w-auto"

  def company(assigns) do
    assigns =
      assigns
      |> assign(:kind, rem(abs(assigns.variant), 5))
      |> assign(stroke: @stroke, backdrop: @backdrop, ground: @ground)

    ~H"""
    <svg viewBox="0 0 200 160" class={@class} aria-hidden="true" fill="none">
      <circle cx="100" cy="82" r="62" class={@backdrop} />
      <ellipse cx="100" cy="142" rx="66" ry="6" class={@ground} />

      <%= case @kind do %>
        <% 0 -> %>
          <%!-- Office tower with a side block and a flag on top. --%>
          <line x1="95" y1="34" x2="95" y2="18" class={@stroke} stroke-width="2" />
          <path d="M95 18h15l-4 5 4 5H95z" class="fill-base-content/70" />
          <rect
            x="72"
            y="34"
            width="46"
            height="106"
            rx="3"
            class={[@tone, @stroke]}
            stroke-width="2"
          />
          <rect
            x="118"
            y="70"
            width="30"
            height="70"
            rx="3"
            class={["fill-base-100", @stroke]}
            stroke-width="2"
          />
          <%= for y <- [44, 58, 72, 86, 100], x <- [80, 92, 104] do %>
            <rect x={x} y={y} width="6" height="8" rx="1" class="fill-base-100" />
          <% end %>
          <%= for y <- [80, 94, 108], x <- [125, 137] do %>
            <rect x={x} y={y} width="5" height="7" rx="1" class="fill-base-content/70" />
          <% end %>
          <rect x="88" y="120" width="14" height="20" rx="1" class="fill-base-content/80" />
          <circle cx="56" cy="120" r="11" class="fill-base-content/20" />
          <rect x="55" y="126" width="2" height="14" class="fill-base-content/60" />
        <% 1 -> %>
          <%!-- Shop with a striped awning and a sign. --%>
          <rect x="68" y="34" width="64" height="14" rx="7" class="fill-base-content/85" />
          <circle :for={x <- [88, 100, 112]} cx={x} cy="41" r="2.5" class="fill-base-content/70" />
          <rect
            x="50"
            y="56"
            width="100"
            height="84"
            rx="2"
            class={[@tone, @stroke]}
            stroke-width="2"
          />
          <%= for {x, i} <- Enum.with_index([46, 67, 88, 109, 130]) do %>
            <rect
              x={x}
              y="50"
              width="22"
              height="16"
              class={if(rem(i, 2) == 0, do: "fill-base-content/70", else: "fill-base-100")}
            />
            <circle
              cx={x + 11}
              cy="66"
              r="11"
              class={if(rem(i, 2) == 0, do: "fill-base-content/70", else: "fill-base-100")}
            />
          <% end %>
          <path d="M46 50h106" class={@stroke} stroke-width="2" stroke-linecap="round" />
          <rect
            x="58"
            y="86"
            width="44"
            height="32"
            rx="2"
            class={["fill-base-100", @stroke]}
            stroke-width="2"
          />
          <circle cx="70" cy="110" r="5" class="fill-base-content/25" />
          <circle cx="82" cy="110" r="5" class="fill-base-content/25" />
          <circle cx="94" cy="110" r="5" class="fill-base-content/30" />
          <rect x="110" y="86" width="28" height="54" rx="2" class="fill-base-content/80" />
          <circle cx="132" cy="114" r="2" class="fill-base-content/70" />
        <% 2 -> %>
          <%!-- Factory with a saw-tooth roof and a chimney. --%>
          <circle cx="142" cy="34" r="7" class="fill-base-content/10" />
          <circle cx="154" cy="24" r="9" class="fill-base-content/10" />
          <rect
            x="128"
            y="44"
            width="14"
            height="44"
            class={["fill-base-100", @stroke]}
            stroke-width="2"
          />
          <rect x="128" y="50" width="14" height="6" class="fill-base-content/70" />
          <path
            d="M44 140V84l24-14v14l24-14v14l24-14v14h40v56z"
            class={[@tone, @stroke]}
            stroke-width="2"
            stroke-linejoin="round"
          />
          <rect
            :for={x <- [54, 78, 102]}
            x={x}
            y="96"
            width="16"
            height="12"
            rx="1"
            class="fill-base-100"
          />
          <rect x="126" y="108" width="20" height="32" rx="1" class="fill-base-content/80" />
          <rect x="54" y="118" width="60" height="6" rx="3" class="fill-base-content/70" />
        <% 3 -> %>
          <%!-- Warehouse with an arched roof, a roller door and crates. --%>
          <path
            d="M48 140V86q52-40 104 0v54z"
            class={[@tone, @stroke]}
            stroke-width="2"
            stroke-linejoin="round"
          />
          <rect x="94" y="62" width="12" height="8" rx="1" class="fill-base-100" />
          <rect
            x="76"
            y="98"
            width="48"
            height="42"
            class={["fill-base-100", @stroke]}
            stroke-width="2"
          />
          <line
            :for={y <- [106, 114, 122, 130]}
            x1="76"
            x2="124"
            y1={y}
            y2={y}
            class="stroke-base-content/25"
            stroke-width="2"
          />
          <rect
            x="132"
            y="120"
            width="20"
            height="20"
            class={["fill-base-content/70", @stroke]}
            stroke-width="2"
          />
          <rect
            x="138"
            y="104"
            width="14"
            height="16"
            class={["fill-base-content/30", @stroke]}
            stroke-width="2"
          />
          <rect
            x="50"
            y="124"
            width="16"
            height="16"
            class={["fill-base-content/30", @stroke]}
            stroke-width="2"
          />
        <% _ -> %>
          <%!-- Studio: a pitched roof, a round window, a plant and the sun. --%>
          <circle cx="152" cy="40" r="10" class="fill-base-content/70" />
          <path
            d="M56 140V88l44-32 44 32v52z"
            class={[@tone, @stroke]}
            stroke-width="2"
            stroke-linejoin="round"
          />
          <circle
            cx="100"
            cy="92"
            r="11"
            class={["fill-base-100", @stroke]}
            stroke-width="2"
          />
          <path d="M100 81v22M89 92h22" class="stroke-base-content/30" stroke-width="2" />
          <path d="M90 140v-18a10 10 0 0 1 20 0v18z" class="fill-base-content/80" />
          <rect x="66" y="112" width="14" height="12" rx="1" class="fill-base-100" />
          <rect x="120" y="112" width="14" height="12" rx="1" class="fill-base-100" />
          <ellipse cx="160" cy="116" rx="7" ry="11" class="fill-base-content/20" />
          <rect x="153" y="124" width="14" height="16" rx="2" class="fill-base-content/70" />
      <% end %>
    </svg>
    """
  end

  @doc "Someone waving beside an invoice: the first onboarding step."
  attr :class, :any, default: "h-44 w-auto"

  def welcome(assigns) do
    assigns = assign(assigns, stroke: @stroke, backdrop: @backdrop, ground: @ground)

    ~H"""
    <svg viewBox="0 0 240 200" class={@class} aria-hidden="true" fill="none">
      <circle cx="122" cy="98" r="78" class={@backdrop} />
      <ellipse cx="120" cy="178" rx="84" ry="7" class={@ground} />

      <g>
        <rect
          x="118"
          y="34"
          width="90"
          height="116"
          rx="8"
          class={["fill-base-100", @stroke]}
          stroke-width="2"
        />
        <rect x="130" y="48" width="38" height="7" rx="3.5" class="fill-base-content/70" />
        <rect
          :for={y <- [66, 78, 90, 102]}
          x="130"
          y={y}
          width="66"
          height="4"
          rx="2"
          class="fill-base-content/15"
        />
        <rect x="164" y="124" width="32" height="10" rx="3" class="fill-base-content/70" />
        <rect x="130" y="126" width="22" height="5" rx="2.5" class="fill-base-content/40" />
      </g>

      <rect x="62" y="150" width="11" height="28" rx="4" class="fill-base-content/80" />
      <rect x="78" y="150" width="11" height="28" rx="4" class="fill-base-content/80" />
      <rect x="54" y="94" width="44" height="62" rx="18" class="fill-base-content/45" />
      <path
        d="M60 104 50 132"
        class="stroke-base-content/45"
        stroke-width="10"
        stroke-linecap="round"
      />
      <path
        d="M92 104 108 76"
        class="stroke-base-content/45"
        stroke-width="10"
        stroke-linecap="round"
      />
      <circle cx="110" cy="70" r="7" class="fill-base-content/15" />
      <circle cx="49" cy="136" r="6" class="fill-base-content/15" />
      <circle cx="76" cy="74" r="16" class="fill-base-content/15" />
      <path d="M60 72a16 16 0 0 1 32-2c-6 2-16 1-22-6-2 4-6 7-10 8z" class="fill-base-content/85" />

      <path
        d="M124 62l2 5 5 2-5 2-2 5-2-5-5-2 5-2z"
        class="fill-base-content/70"
      />
      <path
        d="M100 48l1.5 3.5 3.5 1.5-3.5 1.5-1.5 3.5-1.5-3.5-3.5-1.5 3.5-1.5z"
        class="fill-base-content/30"
      />
    </svg>
    """
  end

  @doc "An ID card being filled in: the \"about you\" step."
  attr :class, :any, default: "h-44 w-auto"

  def profile(assigns) do
    assigns = assign(assigns, stroke: @stroke, backdrop: @backdrop, ground: @ground)

    ~H"""
    <svg viewBox="0 0 240 200" class={@class} aria-hidden="true" fill="none">
      <circle cx="120" cy="98" r="78" class={@backdrop} />
      <ellipse cx="120" cy="178" rx="80" ry="7" class={@ground} />

      <g>
        <rect
          x="44"
          y="52"
          width="152"
          height="104"
          rx="12"
          class={["fill-base-100", @stroke]}
          stroke-width="2"
        />
        <path d="M45 76V64a11 11 0 0 1 11-11h128a11 11 0 0 1 11 11v12z" class="fill-base-content/70" />
        <circle cx="100" cy="64" r="3" class="fill-base-100" />
        <rect x="108" y="61" width="32" height="6" rx="3" class="fill-base-100/80" />

        <circle cx="84" cy="114" r="22" class="fill-base-content/10" />
        <circle cx="84" cy="107" r="8" class="fill-base-content/75" />
        <path d="M68 130a16 14 0 0 1 32 0z" class="fill-base-content/75" />

        <rect x="118" y="96" width="58" height="7" rx="3.5" class="fill-base-content/75" />
        <rect x="118" y="110" width="44" height="5" rx="2.5" class="fill-base-content/20" />
        <rect x="118" y="121" width="52" height="5" rx="2.5" class="fill-base-content/20" />
        <rect x="118" y="132" width="30" height="5" rx="2.5" class="fill-base-content/20" />
      </g>

      <g transform="rotate(35 186 150)">
        <rect
          x="178"
          y="104"
          width="14"
          height="56"
          rx="2"
          class={["fill-base-content/70", @stroke]}
          stroke-width="2"
        />
        <path d="M178 160l7 14 7-14z" class={["fill-base-content/15", @stroke]} stroke-width="2" />
        <rect x="178" y="104" width="14" height="8" class="fill-base-content/25" />
      </g>
    </svg>
    """
  end

  @doc "Two buildings, a badge and the people in them: the organisation step."
  attr :class, :any, default: "h-44 w-auto"

  def organization(assigns) do
    assigns = assign(assigns, stroke: @stroke, backdrop: @backdrop, ground: @ground)

    ~H"""
    <svg viewBox="0 0 240 200" class={@class} aria-hidden="true" fill="none">
      <circle cx="120" cy="98" r="78" class={@backdrop} />
      <ellipse cx="120" cy="176" rx="88" ry="7" class={@ground} />

      <rect
        x="62"
        y="56"
        width="56"
        height="118"
        rx="4"
        class={["fill-base-200", @stroke]}
        stroke-width="2"
      />
      <%= for y <- [68, 84, 100, 116, 132], x <- [72, 86, 100] do %>
        <rect x={x} y={y} width="8" height="9" rx="1" class="fill-base-100" />
      <% end %>
      <rect
        x="118"
        y="96"
        width="50"
        height="78"
        rx="4"
        class={["fill-base-100", @stroke]}
        stroke-width="2"
      />
      <%= for y <- [108, 124, 140], x <- [128, 146] do %>
        <rect x={x} y={y} width="10" height="9" rx="1" class="fill-base-content/70" />
      <% end %>
      <rect x="82" y="152" width="16" height="22" rx="1" class="fill-base-content/80" />

      <g>
        <circle cx="168" cy="70" r="22" class={["fill-base-content/70", @stroke]} stroke-width="2" />
        <path
          d="M158 70l7 7 13-14"
          class="stroke-base-content/85"
          stroke-width="4"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </g>

      <circle cx="44" cy="150" r="7" class="fill-base-content/15" />
      <rect x="36" y="158" width="16" height="16" rx="7" class="fill-base-content/25" />
      <circle cx="194" cy="150" r="7" class="fill-base-content/15" />
      <rect x="186" y="158" width="16" height="16" rx="7" class="fill-base-content/40" />
    </svg>
    """
  end

  @doc """
  A shield with a check drawing itself in, and confetti: after choosing a
  company, and at the end of onboarding.
  """
  attr :class, :any, default: "h-48 w-auto"

  def success(assigns) do
    assigns = assign(assigns, stroke: @stroke, backdrop: @backdrop, ground: @ground)

    ~H"""
    <svg viewBox="0 0 240 200" class={@class} aria-hidden="true" fill="none">
      <circle cx="120" cy="100" r="80" class={@backdrop} />
      <ellipse cx="120" cy="182" rx="56" ry="6" class={@ground} />

      <g class="qb-pop-in">
        <path
          d="M120 30l52 19v46c0 36-23 59-52 71-29-12-52-35-52-71V49z"
          class={["fill-base-100", @stroke]}
          stroke-width="2"
          stroke-linejoin="round"
        />
        <path
          d="M120 43l41 15v38c0 29-18 48-41 58-23-10-41-29-41-58V58z"
          class="fill-base-content/70"
        />
        <path
          d="M101 99l14 14 27-29"
          pathLength="1"
          class="stroke-base-100 qb-draw"
          stroke-width="9"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </g>

      <g class="qb-confetti">
        <rect
          x="52"
          y="52"
          width="8"
          height="8"
          rx="1"
          transform="rotate(20 56 56)"
          class="fill-base-content/40"
        />
        <rect
          x="180"
          y="44"
          width="8"
          height="8"
          rx="1"
          transform="rotate(-15 184 48)"
          class="fill-base-content/45"
        />
        <circle cx="194" cy="112" r="4.5" class="fill-base-content/50" />
        <circle cx="44" cy="118" r="4.5" class="fill-base-content/85" />
        <rect
          x="64"
          y="148"
          width="7"
          height="7"
          rx="1"
          transform="rotate(35 67 151)"
          class="fill-base-content/40"
        />
        <rect
          x="170"
          y="150"
          width="7"
          height="7"
          rx="1"
          transform="rotate(-30 173 153)"
          class="fill-base-content/25"
        />
        <path d="M90 28l2 5 5 2-5 2-2 5-2-5-5-2 5-2z" class="fill-base-content/70" />
        <path d="M156 20l1.5 4 4 1.5-4 1.5-1.5 4-1.5-4-4-1.5 4-1.5z" class="fill-base-content/30" />
      </g>
    </svg>
    """
  end
end
