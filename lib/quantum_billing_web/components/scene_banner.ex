defmodule QuantumBillingWeb.SceneBanner do
  @moduledoc """
  A generated landscape for the profile page's banner.

  The scene is drawn on the server as inline SVG from a single integer seed:
  the time of day and its palette, ridges of mountains built by midpoint
  displacement and fading into the haze behind them, clouds, stars or birds,
  and in the foreground either pines along the nearest ridge or a lake holding
  its reflection. The same seed always draws the same picture.

  Inline SVG rather than an image: there is nothing to store, nothing fetched
  from another origin, and nothing for the content security policy to allow.

  The random state is threaded through explicitly (`:rand.uniform_s/1`), never
  kept in the process dictionary, so drawing a banner does not disturb the
  calling process's own random numbers.
  """
  use Phoenix.Component

  @width 1200
  @height 320
  @segments 64

  @palettes [
    %{
      label: "Dawn",
      sky: {"#2e3a6e", "#b783b5", "#f8c9a0"},
      glow: "#ffd9b0",
      sun: "#fff1dc",
      haze: "#e9b8c4",
      cloud: "#ffe1e8",
      snow: "#fbe7ef",
      mountains: ["#9a86b4", "#7a6aa0", "#5a4e84", "#3e3866", "#272446"],
      birds: "#2a2440",
      celestial: {:sun, 165..195, 24..32},
      stars: 0
    },
    %{
      label: "Morning",
      sky: {"#3d7fd1", "#86bdea", "#dff0fb"},
      glow: "#fffbe8",
      sun: "#fffef5",
      haze: "#d6e8f4",
      cloud: "#ffffff",
      snow: "#ffffff",
      mountains: ["#9fb9d1", "#7c9fbc", "#5c8a8c", "#3e6d5d", "#24493b"],
      birds: "#1f2d3a",
      celestial: {:sun, 45..85, 18..24},
      stars: 0
    },
    %{
      label: "Golden hour",
      sky: {"#4a6fae", "#e9a97e", "#fde3a3"},
      glow: "#ffe2a0",
      sun: "#fff4cf",
      haze: "#f6caa0",
      cloud: "#fff0d6",
      snow: "#fff3df",
      mountains: ["#c39a82", "#9c7562", "#76564a", "#4f3a36", "#2c2124"],
      birds: "#2c2124",
      celestial: {:sun, 115..150, 22..28},
      stars: 0
    },
    %{
      label: "Sunset",
      sky: {"#231a4a", "#c8475d", "#f7a443"},
      glow: "#ffbf6b",
      sun: "#ffe1a1",
      haze: "#e57a68",
      cloud: "#ffb08a",
      snow: "#ffd1c2",
      mountains: ["#94496b", "#6e3b5d", "#4c2e4c", "#321f3a", "#1b1224"],
      birds: "#1b1224",
      celestial: {:sun, 150..185, 28..36},
      stars: 0
    },
    %{
      label: "Dusk",
      sky: {"#0f1733", "#36457f", "#cf8a77"},
      glow: "#f2a07f",
      sun: "#ffc29b",
      haze: "#7d6f9a",
      cloud: "#a99cc4",
      snow: "#c9c6e6",
      mountains: ["#5a6292", "#424a79", "#2f355c", "#1f2442", "#12152a"],
      birds: nil,
      celestial: {:sun, 200..225, 26..32},
      stars: 25
    },
    %{
      label: "Night",
      sky: {"#03061a", "#0d1838", "#223060"},
      glow: "#c9d4ff",
      sun: "#f3f0dc",
      haze: "#2b3a6b",
      cloud: "#3a4673",
      snow: "#c8d2f0",
      mountains: ["#2b3459", "#1f2848", "#161d37", "#0f1429", "#070a17"],
      birds: nil,
      celestial: {:moon, 45..90, 16..22},
      stars: 80
    }
  ]

  attr :id, :string, required: true
  attr :seed, :integer, required: true
  attr :class, :any, default: nil

  @doc "The banner as an SVG that covers its box, anchored to the ground."
  def scene_banner(assigns) do
    assigns = assign(assigns, :scene, scene(assigns.seed))

    ~H"""
    <svg
      id={@id}
      viewBox="0 0 1200 320"
      preserveAspectRatio="xMidYMax slice"
      class={@class}
      role="img"
      aria-label={"Generated #{String.downcase(@scene.label)} landscape"}
      data-scene={@scene.label}
      data-seed={@seed}
      xmlns="http://www.w3.org/2000/svg"
    >
      <defs>
        <linearGradient id={"#{@id}-sky"} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color={elem(@scene.palette.sky, 0)} />
          <stop offset="0.55" stop-color={elem(@scene.palette.sky, 1)} />
          <stop offset="1" stop-color={elem(@scene.palette.sky, 2)} />
        </linearGradient>

        <radialGradient id={"#{@id}-glow"}>
          <stop offset="0" stop-color={@scene.palette.glow} stop-opacity="0.7" />
          <stop offset="0.35" stop-color={@scene.palette.glow} stop-opacity="0.25" />
          <stop offset="1" stop-color={@scene.palette.glow} stop-opacity="0" />
        </radialGradient>

        <linearGradient
          :for={{ridge, i} <- Enum.with_index(@scene.ridges)}
          id={"#{@id}-ridge-#{i}"}
          x1="0"
          y1="0"
          x2="0"
          y2="1"
        >
          <stop offset="0" stop-color={ridge.top} />
          <stop offset="1" stop-color={ridge.bottom} />
        </linearGradient>

        <filter id={"#{@id}-soft"} x="-30%" y="-100%" width="160%" height="300%">
          <feGaussianBlur stdDeviation="9" />
        </filter>

        <mask :if={@scene.celestial.kind == :moon} id={"#{@id}-moon"}>
          <rect width="1200" height="320" fill="black" />
          <circle cx={@scene.celestial.x} cy={@scene.celestial.y} r={@scene.celestial.r} fill="white" />
          <circle
            cx={num(@scene.celestial.x + @scene.celestial.r * 0.45)}
            cy={num(@scene.celestial.y - @scene.celestial.r * 0.25)}
            r={@scene.celestial.r}
            fill="black"
          />
        </mask>

        <clipPath :if={@scene.snow} id={"#{@id}-snow"}>
          <path d={@scene.snow} />
        </clipPath>

        <%= if @scene.lake do %>
          <linearGradient id={"#{@id}-lake"} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stop-color={@scene.lake.top} />
            <stop offset="1" stop-color={@scene.lake.bottom} />
          </linearGradient>
          <clipPath id={"#{@id}-water"}>
            <rect y={@scene.lake.y} width="1200" height={320 - @scene.lake.y} />
          </clipPath>
        <% end %>
      </defs>

      <rect width="1200" height="320" fill={"url(##{@id}-sky)"} />

      <g :if={@scene.stars != []} fill="#ffffff">
        <circle :for={{x, y, r, o} <- @scene.stars} cx={x} cy={y} r={r} opacity={o} />
      </g>

      <circle
        cx={@scene.celestial.x}
        cy={@scene.celestial.y}
        r={num(@scene.celestial.r * 6)}
        fill={"url(##{@id}-glow)"}
      />
      <circle
        :if={@scene.celestial.kind == :sun}
        cx={@scene.celestial.x}
        cy={@scene.celestial.y}
        r={@scene.celestial.r}
        fill={@scene.palette.sun}
      />
      <rect
        :if={@scene.celestial.kind == :moon}
        width="1200"
        height="320"
        fill={@scene.palette.sun}
        mask={"url(##{@id}-moon)"}
      />

      <g filter={"url(##{@id}-soft)"} fill={@scene.palette.cloud}>
        <g :for={cloud <- @scene.clouds} opacity={cloud.opacity}>
          <ellipse :for={{cx, cy, rx, ry} <- cloud.puffs} cx={cx} cy={cy} rx={rx} ry={ry} />
        </g>
      </g>

      <g
        :if={@scene.birds != []}
        fill="none"
        stroke={@scene.palette.birds}
        stroke-width="1.4"
        stroke-linecap="round"
        opacity="0.7"
      >
        <path :for={d <- @scene.birds} d={d} />
      </g>

      <%= for {ridge, i} <- Enum.with_index(@scene.ridges) do %>
        <path d={ridge.d} fill={"url(##{@id}-ridge-#{i})"} />
        <path
          :if={i == 0 and @scene.snow}
          d={ridge.d}
          fill={@scene.palette.snow}
          opacity="0.85"
          clip-path={"url(##{@id}-snow)"}
        />
        <ellipse
          :if={i < length(@scene.ridges) - 1}
          cx="600"
          cy={ridge.mist_y}
          rx="760"
          ry="20"
          fill={@scene.palette.haze}
          opacity="0.3"
          filter={"url(##{@id}-soft)"}
        />
      <% end %>

      <%= if @scene.lake do %>
        <rect y={@scene.lake.y} width="1200" height={320 - @scene.lake.y} fill={"url(##{@id}-lake)"} />
        <%!-- The clip sits on a wrapper: on the path itself it would be mirrored with it. --%>
        <g clip-path={"url(##{@id}-water)"}>
          <path
            d={@scene.lake.reflection}
            fill={@scene.lake.reflection_color}
            opacity="0.55"
            transform={"translate(0 #{2 * @scene.lake.y}) scale(1 -1)"}
          />
        </g>
        <rect
          :for={{x, y, w, o} <- @scene.lake.shimmer}
          x={x}
          y={y}
          width={w}
          height="1.2"
          rx="0.6"
          fill={@scene.palette.glow}
          opacity={o}
        />
        <rect y={@scene.lake.y - 1} width="1200" height="2.5" fill={@scene.lake.shore} opacity="0.7" />
      <% end %>

      <path :if={@scene.trees} d={@scene.trees.d} fill={@scene.trees.color} />
    </svg>
    """
  end

  @doc """
  The scene for a seed, as data: palette, celestial body, sky details, ridges
  and foreground. Pure, so the same seed always returns the same map.
  """
  def scene(seed) when is_integer(seed) do
    rng = :rand.seed_s(:exsss, abs(seed) + 1)

    {palette, rng} = pick(@palettes, rng)
    {lake?, rng} = chance(0.4, rng)
    {layer_count, rng} = int(4..5, rng)

    {celestial, rng} = celestial(palette, rng)
    {stars, rng} = stars(palette.stars, rng)
    {clouds, rng} = clouds(palette, rng)
    {birds, rng} = birds(palette, rng)

    front_floor = if lake?, do: 228, else: 282
    {ridges, rng} = ridges(palette, layer_count, front_floor, rng)

    {snow, rng} = snow(ridges, rng)
    {lake, rng} = if lake?, do: lake(palette, ridges, rng), else: {nil, rng}
    {trees, _rng} = if lake?, do: {nil, rng}, else: trees(List.last(ridges), rng)

    %{
      label: palette.label,
      palette: palette,
      celestial: celestial,
      stars: stars,
      clouds: clouds,
      birds: birds,
      ridges: Enum.map(ridges, &Map.drop(&1, [:points])),
      snow: snow,
      lake: lake,
      trees: trees
    }
  end

  ## Sky

  defp celestial(%{celestial: {kind, ys, rs}}, rng) do
    {x, rng} = float(180, 1020, rng)
    {y, rng} = int(ys, rng)
    {r, rng} = int(rs, rng)
    {%{kind: kind, x: num(x), y: y, r: r}, rng}
  end

  defp stars(0, rng), do: {[], rng}

  defp stars(count, rng) do
    Enum.map_reduce(1..count, rng, fn _, rng ->
      {x, rng} = float(0, @width, rng)
      {y, rng} = float(0, 190, rng)
      {r, rng} = float(0.4, 1.5, rng)
      {o, rng} = float(0.3, 1.0, rng)
      {{num(x), num(y), num(r), num(o)}, rng}
    end)
  end

  defp clouds(%{stars: stars}, rng) when stars > 40, do: {[], rng}

  defp clouds(_palette, rng) do
    {count, rng} = int(2..4, rng)

    Enum.map_reduce(1..count, rng, fn _, rng ->
      {cx, rng} = float(80, 1120, rng)
      {cy, rng} = float(30, 125, rng)
      {opacity, rng} = float(0.35, 0.65, rng)
      {puff_count, rng} = int(4..6, rng)

      {puffs, rng} =
        Enum.map_reduce(1..puff_count, rng, fn _, rng ->
          {dx, rng} = float(-70, 70, rng)
          {dy, rng} = float(-8, 8, rng)
          {rx, rng} = float(30, 75, rng)
          {ry, rng} = float(9, 18, rng)
          {{num(cx + dx), num(cy + dy), num(rx), num(ry)}, rng}
        end)

      {%{opacity: num(opacity), puffs: puffs}, rng}
    end)
  end

  defp birds(%{birds: nil}, rng), do: {[], rng}

  defp birds(_palette, rng) do
    {flock?, rng} = chance(0.6, rng)

    if flock? do
      {count, rng} = int(2..5, rng)
      {fx, rng} = float(200, 1000, rng)
      {fy, rng} = float(60, 140, rng)

      Enum.map_reduce(1..count, rng, fn _, rng ->
        {dx, rng} = float(-60, 60, rng)
        {dy, rng} = float(-20, 20, rng)
        {s, rng} = float(2.5, 4.5, rng)
        x = fx + dx
        y = fy + dy

        d =
          "M#{num(x)},#{num(y)} q#{num(s)},#{num(-s)} #{num(2 * s)},0 q#{num(s)},#{num(-s)} #{num(2 * s)},0"

        {d, rng}
      end)
    else
      {[], rng}
    end
  end

  ## Mountains

  # Back to front: each ridge sits lower, is smoother, and is darker than the
  # one behind it, and its foot fades toward the haze — atmospheric perspective.
  defp ridges(palette, count, front_floor, rng) do
    colors =
      case count do
        5 -> palette.mountains
        4 -> Enum.drop(palette.mountains, 1)
      end

    back_floor = 135
    step = (front_floor - back_floor) / (count - 1)

    colors
    |> Enum.with_index()
    |> Enum.map_reduce(rng, fn {color, i}, rng ->
      floor = back_floor + i * step
      amplitude = 115 * (1 - i / count) + 18
      {roughness, rng} = float(0.5, 0.6, rng)
      {points, rng} = ridge_points(floor, amplitude, roughness, rng)

      ridge = %{
        points: points,
        d: ridge_path(points),
        top: color,
        bottom: mix(color, palette.haze, 0.45 - i * 0.08),
        mist_y: num(floor + 18)
      }

      {ridge, rng}
    end)
  end

  defp ridge_points(floor, amplitude, roughness, rng) do
    {left, rng} = float(floor - amplitude * 0.5, floor + amplitude * 0.2, rng)
    {right, rng} = float(floor - amplitude * 0.5, floor + amplitude * 0.2, rng)

    {heights, rng} =
      displace([left, right], amplitude, roughness, round(:math.log2(@segments)), rng)

    {heights |> Enum.map(&clamp(&1, 12, @height)) |> Enum.with_index(), rng}
  end

  # Midpoint displacement: each pass puts a jittered point between every pair,
  # with the jitter shrinking each pass, which is what makes ridges read as rock.
  defp displace(heights, _amplitude, _roughness, 0, rng), do: {heights, rng}

  defp displace(heights, amplitude, roughness, passes, rng) do
    {mids, rng} =
      heights
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map_reduce(rng, fn [a, b], rng ->
        {jitter, rng} = float(-amplitude, amplitude, rng)
        {(a + b) / 2 + jitter, rng}
      end)

    interleaved = interleave(heights, mids)
    displace(interleaved, amplitude * roughness, roughness, passes - 1, rng)
  end

  defp interleave([last], []), do: [last]
  defp interleave([h | hs], [m | ms]), do: [h, m | interleave(hs, ms)]

  defp ridge_path(points) do
    line = Enum.map_join(points, " L", fn {y, i} -> "#{num(x_at(i))},#{num(y)}" end)
    "M0,#{@height} L" <> line <> " L#{@width},#{@height} Z"
  end

  defp x_at(i), do: i * @width / @segments

  # The height of a ridge at any x, between its sampled points.
  defp ridge_y(points, x) do
    pos = clamp(x / (@width / @segments), 0, @segments)
    i = min(trunc(pos), @segments - 1)
    {a, _} = Enum.at(points, i)
    {b, _} = Enum.at(points, i + 1)
    a + (b - a) * (pos - i)
  end

  # Snow on the farthest ridge, down to a ragged snowline below its summit.
  defp snow([back | _], rng) do
    {snowy?, rng} = chance(0.75, rng)

    if snowy? do
      peak = back.points |> Enum.map(&elem(&1, 0)) |> Enum.min()
      {depth, rng} = float(20, 36, rng)
      line_y = peak + depth

      {edge, rng} =
        Enum.map_reduce(0..div(@width, 40), rng, fn k, rng ->
          {jitter, rng} = float(-6, 6, rng)
          {"#{k * 40},#{num(line_y + jitter)}", rng}
        end)

      {"M0,0 L#{@width},0 L" <> Enum.join(Enum.reverse(edge), " L") <> " Z", rng}
    else
      {nil, rng}
    end
  end

  ## Foreground

  defp lake(palette, ridges, rng) do
    y = 258
    nearest = List.last(ridges)
    {_, sky_mid, sky_low} = palette.sky

    {shimmer, rng} =
      Enum.map_reduce(1..9, rng, fn _, rng ->
        {x, rng} = float(0, 1100, rng)
        {sy, rng} = float(y + 6, 314, rng)
        {w, rng} = float(30, 150, rng)
        {o, rng} = float(0.15, 0.45, rng)
        {{num(x), num(sy), num(w), num(o)}, rng}
      end)

    lake = %{
      y: y,
      top: mix(sky_low, nearest.top, 0.3),
      bottom: mix(sky_mid, nearest.top, 0.6),
      reflection: nearest.d,
      reflection_color: nearest.top,
      shore: List.last(palette.mountains),
      shimmer: shimmer
    }

    {lake, rng}
  end

  # Pines along the nearest ridge, in loose clumps with clearings between.
  defp trees(ridge, rng) do
    {paths, rng} = plant(-10.0, ridge.points, [], rng)
    {%{d: Enum.join(paths, " "), color: ridge.top}, rng}
  end

  defp plant(x, _points, acc, rng) when x > @width + 10, do: {acc, rng}

  defp plant(x, points, acc, rng) do
    {gap, rng} = float(5, 20, rng)
    {grows?, rng} = chance(0.7, rng)

    if grows? do
      {h, rng} = float(14, 44, rng)
      base = ridge_y(points, clamp(x, 0, @width)) + 6
      plant(x + gap, points, [pine(x, base, h) | acc], rng)
    else
      {clearing, rng} = float(10, 60, rng)
      plant(x + gap + clearing, points, acc, rng)
    end
  end

  defp pine(x, base, h) do
    w = h * 0.42

    Enum.map_join(0..2, " ", fn tier ->
      top = base - h + tier * h * 0.27
      bottom = top + h * 0.46
      half = w / 2 * (0.55 + tier * 0.22)
      "M#{num(x)},#{num(top)} L#{num(x + half)},#{num(bottom)} L#{num(x - half)},#{num(bottom)} Z"
    end) <> " M#{num(x - 1)},#{num(base - h * 0.2)} h2 V#{num(base + 4)} h-2 Z"
  end

  ## Randomness and arithmetic

  defp float(lo, hi, rng) do
    {u, rng} = :rand.uniform_s(rng)
    {lo + (hi - lo) * u, rng}
  end

  defp int(lo..hi//_, rng) do
    {n, rng} = :rand.uniform_s(hi - lo + 1, rng)
    {lo + n - 1, rng}
  end

  defp chance(p, rng) do
    {u, rng} = :rand.uniform_s(rng)
    {u < p, rng}
  end

  defp pick(list, rng) do
    {n, rng} = :rand.uniform_s(length(list), rng)
    {Enum.at(list, n - 1), rng}
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  defp num(v) when is_integer(v), do: v
  defp num(v), do: Float.round(v * 1.0, 1)

  # Mixes two "#rrggbb" colours; t = 0 is all `a`, 1 is all `b`.
  defp mix(a, b, t) do
    t = clamp(t, 0, 1)

    [rgb(a), rgb(b)]
    |> Enum.zip_with(fn [x, y] -> round(x + (y - x) * t) end)
    |> then(fn channels ->
      "#" <> Enum.map_join(channels, &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
    end)
    |> String.downcase()
  end

  defp rgb("#" <> hex) do
    for <<pair::binary-size(2) <- hex>>, do: String.to_integer(pair, 16)
  end
end
