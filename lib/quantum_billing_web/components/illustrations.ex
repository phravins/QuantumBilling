defmodule QuantumBillingWeb.Illustrations do
  @moduledoc """
  The illustrations on the focus screens: the company picker, the "you're in"
  screen after choosing a company, and first-sign-in onboarding.

  Hand-drawn ink style in black and white: people drawn with a bold outline
  over paper-white fills, solid ink hair and clothes, and soft grey shapes
  behind them. Every scene is built from the same `person/1` figure, so the
  set reads as one hand.

  Inline SVG, so there is no file to fetch and nothing for the Content
  Security Policy to allow. "Ink" is `base-content` and "paper" is `base-100`,
  so the drawings invert with the rest of the app in dark mode. Every colour
  is a literal class so Tailwind emits it.

  Decoration only: each SVG is `aria-hidden`, and the screen around it says in
  words whatever the picture shows.
  """
  use Phoenix.Component

  @doc """
  Someone at work, for a company card: at a laptop, behind a shop counter, in
  a hard hat, carrying a box, or at a drawing board. Five, so cards side by
  side do not look alike.

  `variant` picks the scene (any integer; it wraps), `tone` the fill of the
  shape behind it (a literal `fill-*` class from the caller).
  """
  attr :variant, :integer, default: 0
  attr :tone, :string, default: "fill-base-content/10"
  attr :class, :any, default: "h-28 w-auto"

  def company(assigns) do
    assigns = assign(assigns, :kind, rem(abs(assigns.variant), 5))

    ~H"""
    <svg viewBox="0 0 200 160" class={@class} aria-hidden="true" fill="none">
      <path
        d="M40 46 C52 20 104 12 140 22 C176 32 192 66 186 100 C180 134 146 152 104 150 C62 148 22 132 16 100 C12 76 28 66 40 46 Z"
        class={@tone}
      />

      <%= case @kind do %>
        <% 0 -> %>
          <%!-- Office: at a laptop, a tower behind. --%>
          <g class="stroke-base-content" stroke-width="3" stroke-linejoin="round">
            <path d="M132 150 V40 H174 V150" class="fill-base-100" />
            <path
              :for={y <- [52, 68, 84, 100, 116]}
              d={"M142 #{y} h8 M158 #{y} h8"}
              stroke-linecap="round"
            />
          </g>
          <.sparkle x={30} y={40} r={8} />
          <.person x={36} y={44} s={0.95} hair={:short} glasses shirt={:ink} />
          <g class="stroke-base-content" stroke-width="3" stroke-linejoin="round">
            <path d="M44 116 H124 L116 154 H52 Z" class="fill-base-content" />
            <circle cx="84" cy="134" r="5" class="fill-base-100" stroke="none" />
          </g>
        <% 1 -> %>
          <%!-- Shop: behind the counter under a striped awning, waving. --%>
          <g class="stroke-base-content" stroke-width="3" stroke-linejoin="round">
            <path
              :for={{x, i} <- Enum.with_index([24, 52, 80, 108, 136])}
              d={"M#{x} 14 H#{x + 28} V34 C#{x + 28} 44 #{x} 44 #{x} 34 Z"}
              class={if(rem(i, 2) == 0, do: "fill-base-content", else: "fill-base-100")}
            />
          </g>
          <.person x={56} y={50} s={0.92} hair={:bun} shirt={:paper}>
            <:arms>
              <.arm d="M78 86 C92 82 98 66 98 48" shirt={:paper} />
              <.hand x={98} y={42} />
              <.wave_marks />
            </:arms>
          </.person>
          <g class="stroke-base-content" stroke-width="3" stroke-linejoin="round">
            <path d="M20 124 H180 V156 H20 Z" class="fill-base-100" />
            <path d="M28 136 H172" stroke-linecap="round" stroke-dasharray="2 9" />
            <path d="M30 124 V108 C30 100 52 100 52 108 V124" class="fill-base-100" />
            <path d="M36 106 C36 98 46 98 46 106" />
          </g>
        <% 2 -> %>
          <%!-- Workshop: hard hat, holding up a gear, a saw-tooth roof behind. --%>
          <path
            d="M118 150 V70 L138 58 V70 L158 58 V70 L178 58 V150"
            class="fill-base-100 stroke-base-content"
            stroke-width="3"
            stroke-linejoin="round"
          />
          <.person x={26} y={50} s={0.9} hair={:hat} beard shirt={:paper}>
            <:arms>
              <.arm d="M22 86 C14 92 18 98 28 96" shirt={:paper} />
              <.arm d="M78 86 C86 92 82 98 72 96" shirt={:paper} />
            </:arms>
            <:front>
              <.gear x={50} y={92} />
              <.hand x={28} y={96} />
              <.hand x={72} y={96} />
            </:front>
          </.person>
          <.sparkle x={170} y={34} r={7} />
        <% 3 -> %>
          <%!-- Warehouse: carrying a parcel, a stack of boxes behind. --%>
          <g class="fill-base-100 stroke-base-content" stroke-width="3" stroke-linejoin="round">
            <path d="M130 116 H176 V152 H130 Z" />
            <path d="M138 84 H172 V116 H138 Z" />
            <path d="M153 116 V128 M155 84 V94" stroke-linecap="round" />
          </g>
          <.person x={22} y={44} s={0.95} hair={:curly} shirt={:paper}>
            <:arms>
              <.arm d="M22 86 C14 92 14 98 18 104" shirt={:paper} />
              <.arm d="M78 86 C86 92 86 98 82 104" shirt={:paper} />
            </:arms>
            <:front>
              <g class="stroke-base-content" stroke-width="3" stroke-linejoin="round">
                <path d="M14 84 H86 V120 H14 Z" class="fill-base-100" />
                <path d="M42 84 V98 H58 V84" class="fill-base-content" />
                <path d="M24 112 l4 -5 4 5 M34 112 l4 -5 4 5" stroke-linecap="round" />
              </g>
              <.hand x={16} y={104} />
              <.hand x={84} y={104} />
            </:front>
          </.person>
        <% _ -> %>
          <%!-- Studio: long hair, pencil raised to a drawing board. --%>
          <g class="stroke-base-content" stroke-width="3" stroke-linejoin="round">
            <path d="M118 30 H184 V104 H118 Z" class="fill-base-100" />
            <path d="M126 92 L144 66 L156 80 L166 70 L178 92" stroke-linecap="round" />
            <circle cx="166" cy="46" r="7" class="fill-base-content" />
            <path d="M136 104 L128 152 M166 104 L174 152" stroke-linecap="round" />
          </g>
          <.person x={22} y={46} s={0.95} hair={:long} shirt={:ink}>
            <:arms>
              <.arm d="M78 86 C94 82 104 70 110 56" />
              <.hand x={112} y={52} />
              <.pencil x={112} y={52} angle={-35} />
            </:arms>
          </.person>
      <% end %>
    </svg>
    """
  end

  @doc "Someone waving hello, a speech bubble beside them: the first onboarding step."
  attr :class, :any, default: "h-44 w-auto"

  def welcome(assigns) do
    ~H"""
    <svg viewBox="0 0 240 200" class={@class} aria-hidden="true" fill="none">
      <.blob />
      <.person x={50} y={68} s={1.1} hair={:bun} glasses shirt={:ink}>
        <:arms>
          <.arm d="M78 86 C92 82 98 66 98 46" />
          <.hand x={98} y={40} />
          <.wave_marks />
        </:arms>
      </.person>

      <path
        d="M156 22 H214 C220 22 224 26 224 32 V58 C224 64 220 68 214 68 H180 L168 80 L170 68 H156 C150 68 146 64 146 58 V32 C146 26 150 22 156 22 Z"
        class="fill-base-100 stroke-base-content"
        stroke-width="3"
        stroke-linejoin="round"
      />
      <circle :for={x <- [168, 185, 202]} cx={x} cy="45" r="4" class="fill-base-content" />

      <.sparkle x={34} y={52} r={10} />
      <.sparkle x={212} y={150} r={7} />
    </svg>
    """
  end

  @doc "Someone holding up their ID card, a pencil beside it: the \"about you\" step."
  attr :class, :any, default: "h-44 w-auto"

  def profile(assigns) do
    ~H"""
    <svg viewBox="0 0 240 200" class={@class} aria-hidden="true" fill="none">
      <.blob />
      <.person x={65} y={50} s={1.1} hair={:curly} shirt={:paper}>
        <:arms>
          <.arm d="M22 86 C12 94 14 102 22 106" shirt={:paper} />
          <.arm d="M78 86 C88 94 86 102 78 106" shirt={:paper} />
        </:arms>
        <:front>
          <g class="stroke-base-content" stroke-width="3" stroke-linejoin="round">
            <path d="M16 80 H84 V122 H16 Z" class="fill-base-100" />
            <path d="M16 80 H84 V90 H16 Z" class="fill-base-content" />
            <circle cx="32" cy="105" r="8" class="fill-base-content" />
            <path d="M46 100 H74 M46 110 H66" stroke-linecap="round" />
          </g>
          <.hand x={20} y={108} />
          <.hand x={80} y={108} />
        </:front>
      </.person>

      <.pencil x={200} y={100} angle={30} />
      <.sparkle x={40} y={44} r={9} />
    </svg>
    """
  end

  @doc """
  Two colleagues at a growth chart, an idea lighting up between them: the
  organisation step.
  """
  attr :class, :any, default: "h-44 w-auto"

  def organization(assigns) do
    ~H"""
    <svg viewBox="0 0 240 200" class={@class} aria-hidden="true" fill="none">
      <path
        d="M14 120 C10 92 28 74 54 76 C80 78 96 100 92 132 C88 164 60 176 38 168 C18 160 16 140 14 120 Z"
        class="fill-base-content/10"
      />
      <path
        d="M150 96 C162 74 196 70 216 86 C236 102 236 140 218 160 C200 180 160 178 148 156 C138 138 140 112 150 96 Z"
        class="fill-base-content/10"
      />

      <g class="stroke-base-content" stroke-width="3" stroke-linejoin="round">
        <path d="M78 16 H162 V80 H78 Z" class="fill-base-100" />
        <path d="M90 66 V54 M104 66 V44 M118 66 V48 M132 66 V34" stroke-width="7" />
        <path d="M88 70 H152" stroke-linecap="round" />
        <path d="M140 40 L150 28 M150 28 H142 M150 28 V36" stroke-linecap="round" />
      </g>

      <.bulb x={52} y={36} />

      <.person x={4} y={84} s={0.98} hair={:long} shirt={:ink}>
        <:arms>
          <.arm d="M78 86 C92 80 102 68 108 54" />
          <.hand x={110} y={50} />
        </:arms>
      </.person>

      <.person x={130} y={84} s={0.98} flip hair={:short} beard shirt={:paper}>
        <:arms>
          <.arm d="M22 86 C14 92 16 98 24 100" shirt={:paper} />
          <.arm d="M78 86 C86 92 84 98 76 100" shirt={:paper} />
        </:arms>
        <:front>
          <g class="stroke-base-content" stroke-width="3" stroke-linejoin="round">
            <path d="M22 80 H78 V114 H22 Z" class="fill-base-content" />
            <path d="M28 74 H72 V108 H28 Z" class="fill-base-100" />
            <path d="M36 84 H64 M36 92 H58 M36 100 H62" stroke-linecap="round" />
          </g>
          <.hand x={24} y={100} />
          <.hand x={76} y={100} />
        </:front>
      </.person>

      <.sparkle x={186} y={30} r={9} />
    </svg>
    """
  end

  @doc """
  Two people cheering under a tick that draws itself in, with confetti: after
  choosing a company, and at the end of onboarding.
  """
  attr :class, :any, default: "h-48 w-auto"

  def success(assigns) do
    ~H"""
    <svg viewBox="0 0 240 200" class={@class} aria-hidden="true" fill="none">
      <.blob />

      <g class="qb-pop-in">
        <circle cx="120" cy="52" r="30" class="fill-base-content" />
        <path
          d="M106 52l10 10 19-20"
          pathLength="1"
          class="stroke-base-100 qb-draw"
          stroke-width="7"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </g>

      <.person x={18} y={90} s={0.92} hair={:curly} shirt={:paper}>
        <:arms>
          <.arm d="M22 86 C8 80 4 62 6 44" shirt={:paper} />
          <.hand x={6} y={38} />
          <.arm d="M78 86 C92 80 96 62 94 44" shirt={:paper} />
          <.hand x={94} y={38} />
        </:arms>
      </.person>

      <.person x={130} y={90} s={0.92} flip hair={:bun} glasses shirt={:ink}>
        <:arms>
          <.arm d="M22 86 C8 80 4 62 6 44" />
          <.hand x={6} y={38} />
          <.arm d="M78 86 C92 80 96 62 94 44" />
          <.hand x={94} y={38} />
        </:arms>
      </.person>

      <g class="qb-confetti">
        <.sparkle x={64} y={34} r={9} />
        <.sparkle x={184} y={28} r={7} />
        <circle cx="40" cy="70" r="4" class="fill-base-content" />
        <circle cx="206" cy="78" r="4" class="fill-base-content" />
        <path
          d="M86 16 l6 4 M160 14 l-5 5 M24 104 l7 -2 M214 112 l-7 -3"
          class="stroke-base-content"
          stroke-width="3"
          stroke-linecap="round"
        />
      </g>
    </svg>
    """
  end

  ## Parts

  # The soft grey shape behind a single scene.
  defp blob(assigns) do
    ~H"""
    <path
      d="M58 52 C72 22 124 16 156 30 C190 44 206 82 198 120 C190 158 150 180 106 176 C64 172 34 146 32 110 C30 84 44 72 58 52 Z"
      class="fill-base-content/10"
    />
    """
  end

  # One figure, shoulders up, in a 100 × 118 frame: head centred at (50, 32),
  # shoulders at (22, 84) and (78, 84). `arms` are drawn over the body in the
  # same frame, `front` over everything (what the person holds, then hands).
  attr :x, :any, default: 0
  attr :y, :any, default: 0
  attr :s, :any, default: 1
  attr :flip, :boolean, default: false
  attr :hair, :atom, values: [:short, :bun, :curly, :long, :hat], default: :short
  attr :shirt, :atom, values: [:ink, :paper], default: :ink
  attr :glasses, :boolean, default: false
  attr :beard, :boolean, default: false
  slot :arms
  slot :front

  defp person(assigns) do
    ~H"""
    <g transform={place(@x, @y, @s, @flip)} stroke-linecap="round" stroke-linejoin="round">
      <path
        :if={@hair == :long}
        d="M26 38 C22 8 78 8 74 38 L77 78 L23 78 Z"
        class="fill-base-content"
      />

      <path d="M10 118 C10 88 24 68 50 68 C76 68 90 88 90 118 Z" class={shirt_fill(@shirt)} />
      <path
        d="M10 118 C10 88 24 68 50 68 C76 68 90 88 90 118"
        class="stroke-base-content"
        stroke-width="3"
      />
      <path
        :if={@shirt == :paper}
        d="M20 102 l8 -4 M20 110 l8 -4 M72 98 l8 4 M72 106 l8 4"
        class="stroke-base-content"
        stroke-width="2"
      />

      <path d="M43 50 V70 H57 V50 Z" class="fill-base-100 stroke-base-content" stroke-width="3" />
      <%= if @shirt == :ink do %>
        <path d="M40 69 L50 82 L60 69 Z" class="fill-base-100 stroke-base-content" stroke-width="3" />
      <% else %>
        <path d="M41 69 L50 80 L59 69" class="stroke-base-content" stroke-width="3" />
      <% end %>

      <path d="M33 32 C25 29 24 42 33 41" class="fill-base-100 stroke-base-content" stroke-width="3" />
      <path d="M67 32 C75 29 76 42 67 41" class="fill-base-100 stroke-base-content" stroke-width="3" />
      <path
        d="M32 34 C32 16 40 8 50 8 C61 8 68 16 68 34 C68 47 60 56 50 56 C40 56 32 47 32 34 Z"
        class="fill-base-100 stroke-base-content"
        stroke-width="3"
      />

      <circle cx="44" cy="34" r="2.2" class="fill-base-content" />
      <circle cx="56" cy="34" r="2.2" class="fill-base-content" />
      <path
        d="M39 28 Q43 25 47 28 M53 28 Q57 25 61 28"
        class="stroke-base-content"
        stroke-width="2.5"
      />
      <path d="M50 36 Q46 42 50 43" class="stroke-base-content" stroke-width="2.5" />

      <%= if @beard do %>
        <path
          d="M33 40 C35 56 43 62 50 62 C57 62 65 56 67 40 C62 47 57 50 50 50 C43 50 38 47 33 40 Z"
          class="fill-base-content stroke-base-content"
          stroke-width="2"
        />
        <path d="M45 52 Q50 55 55 52" class="stroke-base-100" stroke-width="2.5" />
      <% else %>
        <path d="M44 47 Q50 52 56 47" class="stroke-base-content" stroke-width="2.5" />
      <% end %>

      <%= case @hair do %>
        <% :short -> %>
          <path
            d="M31 32 C28 14 40 4 52 5 C64 5 72 14 69 30 C66 22 60 17 52 18 C46 22 38 22 33 34 Z"
            class="fill-base-content"
          />
        <% :bun -> %>
          <circle cx="50" cy="5" r="7" class="fill-base-content" />
          <path
            d="M31 32 C29 16 40 8 51 8 C63 8 71 17 69 31 C64 20 56 16 48 18 C42 20 36 26 31 32 Z"
            class="fill-base-content"
          />
        <% :curly -> %>
          <path
            d="M31 34 c-5 -4 -3 -11 2 -12 c-3 -6 2 -12 8 -11 c0 -6 8 -9 12 -5 c3 -5 11 -4 12 1 c6 -1 10 5 7 10 c5 2 5 9 1 12 c-4 -6 -10 -9 -17 -9 c-10 0 -19 6 -25 14 Z"
            class="fill-base-100 stroke-base-content"
            stroke-width="3"
          />
          <path d="M42 14 q3 3 0 6 M54 12 q3 3 0 6" class="stroke-base-content" stroke-width="2" />
        <% :long -> %>
          <path
            d="M32 32 C32 14 44 7 52 8 C62 8 68 16 68 30 C60 26 54 20 50 15 C46 24 38 30 32 32 Z"
            class="fill-base-content"
          />
        <% :hat -> %>
          <path d="M30 30 C30 8 70 8 70 30 Z" class="fill-base-content" />
          <path d="M24 30 L76 30" class="stroke-base-content" stroke-width="5" />
          <path d="M50 12 L50 27" class="stroke-base-100" stroke-width="3" />
      <% end %>

      <g :if={@glasses} class="stroke-base-content" stroke-width="2.5">
        <circle cx="44" cy="34" r="5" />
        <circle cx="56" cy="34" r="5" />
        <path d="M49 34 H51" />
      </g>

      {render_slot(@arms)}
      {render_slot(@front)}
    </g>
    """
  end

  # A sleeve: a thick ink stroke, with the shirt colour inside it for a paper
  # shirt, or a stitched seam on an ink one so it does not read as a smear.
  attr :d, :string, required: true
  attr :shirt, :atom, values: [:ink, :paper], default: :ink

  defp arm(assigns) do
    ~H"""
    <path
      d={@d}
      class="stroke-base-content"
      stroke-width="15"
      stroke-linecap="round"
      stroke-linejoin="round"
    />
    <path
      :if={@shirt == :paper}
      d={@d}
      class="stroke-base-100"
      stroke-width="9"
      stroke-linecap="round"
      stroke-linejoin="round"
    />
    <path
      :if={@shirt == :ink}
      d={@d}
      class="stroke-base-100"
      stroke-width="1.5"
      stroke-dasharray="2 8"
      stroke-linecap="round"
    />
    """
  end

  attr :x, :any, required: true
  attr :y, :any, required: true

  defp hand(assigns) do
    ~H"""
    <circle cx={@x} cy={@y} r="6.5" class="fill-base-100 stroke-base-content" stroke-width="3" />
    """
  end

  # Motion lines beside a hand raised at (98, 42) in the person frame.
  defp wave_marks(assigns) do
    ~H"""
    <path
      d="M108 30 l7 -5 M111 42 h8 M108 54 l7 4"
      class="stroke-base-content"
      stroke-width="2.5"
      stroke-linecap="round"
    />
    """
  end

  # A four-pointed spark.
  attr :x, :any, required: true
  attr :y, :any, required: true
  attr :r, :any, default: 10

  defp sparkle(assigns) do
    ~H"""
    <path
      transform={"translate(#{@x} #{@y}) scale(#{@r / 10})"}
      d="M0 -10 C1.5 -2 2 -1.5 10 0 C2 1.5 1.5 2 0 10 C-1.5 2 -2 1.5 -10 0 C-2 -1.5 -1.5 -2 0 -10 Z"
      class="fill-base-content"
    />
    """
  end

  # A pencil, its tip at (x, y), turned by `angle` degrees.
  attr :x, :any, required: true
  attr :y, :any, required: true
  attr :angle, :any, default: 0

  defp pencil(assigns) do
    ~H"""
    <g
      transform={"translate(#{@x} #{@y}) rotate(#{@angle})"}
      class="stroke-base-content"
      stroke-width="3"
      stroke-linejoin="round"
    >
      <path d="M-6 -54 H6 V-14 H-6 Z" class="fill-base-100" />
      <path d="M-6 -54 H6 V-46 H-6 Z" class="fill-base-content" />
      <path d="M-6 -14 L0 0 L6 -14 Z" class="fill-base-100" />
      <path d="M-2.5 -6 L0 0 L2.5 -6 Z" class="fill-base-content" />
    </g>
    """
  end

  # A light bulb with rays: an idea.
  attr :x, :any, required: true
  attr :y, :any, required: true

  defp bulb(assigns) do
    ~H"""
    <g
      transform={"translate(#{@x} #{@y})"}
      class="stroke-base-content"
      stroke-width="3"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path
        d="M-12 0 C-12 -16 12 -16 12 0 C12 8 6 10 6 16 H-6 C-6 10 -12 8 -12 0 Z"
        class="fill-base-100"
      />
      <path d="M-6 16 H6 V24 H-6 Z" class="fill-base-content" />
      <path d="M-4 4 L0 -2 L4 4" />
      <path d="M0 -22 V-28 M-17 -14 L-22 -18 M17 -14 L22 -18 M-20 2 H-26 M20 2 H26" />
    </g>
    """
  end

  # A cog: eight teeth round an ink wheel with a paper hub.
  attr :x, :any, required: true
  attr :y, :any, required: true

  defp gear(assigns) do
    ~H"""
    <g transform={"translate(#{@x} #{@y})"} class="stroke-base-content" stroke-width="3">
      <rect
        :for={angle <- [0, 45, 90, 135, 180, 225, 270, 315]}
        x="-5"
        y="-24"
        width="10"
        height="10"
        rx="1.5"
        transform={"rotate(#{angle})"}
        class="fill-base-content"
      />
      <circle r="17" class="fill-base-content" />
      <circle r="6.5" class="fill-base-100" />
    </g>
    """
  end

  defp place(x, y, s, false), do: "translate(#{x} #{y}) scale(#{s})"
  defp place(x, y, s, true), do: "translate(#{x + 100 * s} #{y}) scale(#{-s} #{s})"

  defp shirt_fill(:ink), do: "fill-base-content"
  defp shirt_fill(:paper), do: "fill-base-100"
end
