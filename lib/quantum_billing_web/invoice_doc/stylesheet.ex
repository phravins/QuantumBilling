defmodule QuantumBillingWeb.InvoiceDoc.Stylesheet do
  @moduledoc """
  The invoice document's stylesheet, as a string.

  Injected in a `<style>` tag on screen and on the print page, which loads no
  `app.css`. Every selector is scoped under `.qb-doc`. The accent comes from the
  `--qb-accent` custom property the renderer sets, so this CSS stays static.
  """

  alias QuantumBillingWeb.InvoiceDoc.Document

  @doc """
  The stylesheet for `document`.

  Option: `:mode`, `:screen` (default) or `:print`, which adds the paper rules and `@page`.
  """
  @spec css(Document.t(), keyword()) :: binary()
  def css(%Document{page: page}, opts \\ []) do
    mode = Keyword.get(opts, :mode, :screen)
    base(page) <> sheet_rules(page) <> mode_rules(mode, page) <> letterhead_print(mode, page)
  end

  defp base(page) do
    """
    .qb-doc {
      --qb-accent: #18181b;
      --qb-rule: #e4e4e7;
      --qb-hairline: #f4f4f5;
      --qb-muted: #{muted_color(page)};
      --qb-label: #{label_color(page)};
      --qb-text: #{text_color(page)};
      --qb-label-case: #{label_case(page)};
      --qb-label-tracking: #{label_tracking(page)};
      --qb-heading-weight: #{heading_weight(page)};
      --qb-heading-color: #{heading_color(page)};
      --qb-heading-family: #{heading_stack(page)};
      max-width: 800px;
      margin: 0 auto;
      font-family: #{font_stack(page.font)};
      font-size: #{page.base_font}px;
      line-height: #{line_height(page)};
      letter-spacing: #{body_tracking(page)};
      font-variant-numeric: #{numerals(page)};
      color: var(--qb-text);
      background: #fff;
    }
    .qb-doc *, .qb-doc *::before, .qb-doc *::after { box-sizing: border-box; }
    .qb-doc p, .qb-doc dl, .qb-doc dd, .qb-doc dt { margin: 0; }

    /* Blocks stack; the gap lives on the block so a removed one takes its
       spacing with it rather than leaving a hole. */
    .qb-doc__block { margin-top: #{block_gap(page)}; }
    .qb-doc__block:first-child { margin-top: 0; }

    /* Two consecutive half-width blocks pack into one row. `min-width: 0` stops
       a long address from pushing the other column off the sheet. */
    .qb-doc__row { display: flex; justify-content: space-between; gap: 32px; }
    .qb-doc__row > .qb-doc__cell { flex: 1 1 0; min-width: 0; }

    .qb-doc--left { text-align: left; }
    .qb-doc--center { text-align: center; }
    .qb-doc--right { text-align: right; }

    .qb-doc__label {
      font-size: 9px;
      text-transform: var(--qb-label-case);
      letter-spacing: var(--qb-label-tracking);
      color: var(--qb-label);
    }
    .qb-doc__name { font-size: 13px; font-weight: 600; margin: 4px 0; }
    .qb-doc__muted { color: var(--qb-muted); white-space: pre-line; margin: 2px 0; }

    .qb-doc__brand { display: flex; align-items: center; gap: 8px; }
    .qb-doc--center .qb-doc__brand { justify-content: center; }
    .qb-doc--right .qb-doc__brand { justify-content: flex-end; }
    .qb-doc__brand svg { width: 26px; height: 26px; flex: none; }
    .qb-doc__brand-name { font-size: 15px; font-weight: 600; letter-spacing: -0.01em; }
    .qb-doc__logo { display: block; }
    .qb-doc--center .qb-doc__logo { margin-left: auto; margin-right: auto; }
    .qb-doc--right .qb-doc__logo { margin-left: auto; }

    .qb-doc__heading {
      font-family: var(--qb-heading-family);
      font-weight: var(--qb-heading-weight);
      letter-spacing: -0.01em;
      margin: 0 0 4px;
      color: var(--qb-heading-color);
    }
    .qb-doc__heading--sm { font-size: #{heading_size(page, :sm)}; }
    .qb-doc__heading--md { font-size: #{heading_size(page, :md)}; }
    .qb-doc__heading--lg { font-size: #{heading_size(page, :lg)}; }
    .qb-doc__heading--accent { color: var(--qb-accent); }

    .qb-doc__meta-line { margin-bottom: 3px; }
    .qb-doc__meta-line dt { display: inline; color: var(--qb-label); margin-right: 10px; }
    .qb-doc__meta-line dd { display: inline; font-weight: 600; }
    .qb-doc__meta-line--strong { font-size: 13px; font-weight: 600; margin: 4px 0; }
    .qb-doc__meta-line--strong dd { font-weight: 600; }

    .qb-doc__divider { border: 0; border-top: 1px solid var(--qb-rule); margin: 20px 0; }

    .qb-doc__items { width: 100%; border-collapse: collapse; margin-top: 8px; }
    .qb-doc__items th {
      text-align: left;
      font-size: 9px;
      text-transform: var(--qb-label-case);
      letter-spacing: var(--qb-label-tracking);
      color: var(--qb-label);
      border-bottom: 1px solid var(--qb-rule);
      padding: #{head_padding(page)};
      white-space: nowrap;
    }
    .qb-doc__items td { padding: #{cell_padding(page)}; border-bottom: 1px solid var(--qb-hairline); }
    .qb-doc__items th:last-child, .qb-doc__items td:last-child { padding-right: 0; }
    .qb-doc__items th.qb-doc--right, .qb-doc__items td.qb-doc--right { text-align: right; }
    .qb-doc__items--grow { width: 100%; }
    .qb-doc__items--plain td { border-bottom: 0; }
    .qb-doc__items--zebra tbody tr:nth-child(even) { background: #fafafa; }

    .qb-doc__totals { margin-left: auto; margin-top: 16px; }
    .qb-doc--left .qb-doc__totals { margin-left: 0; margin-right: auto; }
    .qb-doc--center .qb-doc__totals { margin-left: auto; margin-right: auto; }
    .qb-doc__total-line { display: flex; justify-content: space-between; gap: 16px; padding: 3px 0; }
    .qb-doc__total-line--strong { font-weight: 600; }
    .qb-doc__total-line--accent {
      border-top: 2px solid var(--qb-accent);
      margin-top: 6px;
      padding-top: 8px;
      font-weight: 600;
      font-size: 13px;
      color: var(--qb-accent);
    }

    .qb-doc__signature { display: inline-block; min-width: 200px; }
    .qb-doc__signature-space { border-bottom: 1px solid var(--qb-rule); }
    .qb-doc__signature-caption { margin-top: 6px; }

    .qb-doc__footer {
      padding-top: 10px;
      border-top: 1px solid var(--qb-rule);
      color: var(--qb-muted);
      white-space: pre-line;
    }

    .qb-doc__note-title { font-weight: 600; margin-bottom: 2px; }
    .qb-doc__note--boxed { border: 1px solid var(--qb-rule); border-radius: 4px; padding: 10px 12px; }
    .qb-doc__note--accent { border-left: 3px solid var(--qb-accent); padding: 2px 0 2px 12px; }
    .qb-doc__note--accent .qb-doc__note-title { color: var(--qb-accent); }

    .qb-doc__spacer--edit {
      background: repeating-linear-gradient(135deg, #f4f4f5 0 6px, transparent 6px 12px);
      border-radius: 4px;
    }

    .qb-doc__payment { display: flex; gap: 16px; align-items: flex-start; margin-top: 6px; }
    .qb-doc--right .qb-doc__payment { flex-direction: row-reverse; }
    .qb-doc--center .qb-doc__payment { justify-content: center; }
    .qb-doc__qr { flex: none; }
    .qb-doc__qr svg { display: block; width: 100%; height: 100%; }
    .qb-doc__payment-lines { min-width: 0; }
    .qb-doc__payment-line { margin: 2px 0; }
    .qb-doc__payment-key { color: var(--qb-label); margin-right: 8px; }

    .qb-doc__image { display: block; max-width: 100%; }
    .qb-doc--center .qb-doc__image { margin-left: auto; margin-right: auto; }
    .qb-doc--right .qb-doc__image { margin-left: auto; }
    .qb-doc__placeholder {
      border: 1px dashed var(--qb-rule);
      border-radius: 4px;
      padding: 18px;
      color: var(--qb-label);
      text-align: center;
    }

    /* Background and watermark sit under the blocks; neither changes the flow. */
    .qb-doc--layered { position: relative; overflow: hidden; }
    .qb-doc--layered > .qb-doc__block { position: relative; z-index: 1; }
    .qb-doc__background { position: absolute; z-index: 0; pointer-events: none; }
    .qb-doc__background--page { inset: 0; width: 100%; height: 100%; object-fit: cover; object-position: top center; }
    .qb-doc__background--top { top: 0; left: 0; width: 100%; height: auto; }
    .qb-doc__background--contain { inset: 0; width: 100%; height: 100%; object-fit: contain; }
    .qb-doc__background--o60 { opacity: 0.6; }
    .qb-doc__background--o30 { opacity: 0.3; }
    .qb-doc__watermark {
      position: absolute;
      inset: 0;
      z-index: 0;
      display: flex;
      align-items: center;
      justify-content: center;
      pointer-events: none;
    }
    .qb-doc__watermark span {
      transform: rotate(-30deg);
      font-size: 88px;
      font-weight: 700;
      letter-spacing: 0.08em;
      white-space: nowrap;
      color: var(--qb-accent);
      opacity: 0.08;
    }

    /* The settings panel and the design pad render the document at a fraction
       of its size. Scaling rather than restyling is what keeps the thumbnail an
       honest picture of the page instead of a second design that can flatter it.

       A transform does not affect layout, so the frame reserves the space: a
       percentage `padding-bottom` gives it the paper's aspect ratio, and the
       scaled document is positioned into it. */
    .qb-doc-frame {
      position: relative;
      width: 100%;
      padding-bottom: 141.4%;
      overflow: hidden;
    }
    .qb-doc-frame > .qb-doc-scale { position: absolute; top: 0; left: 0; }
    .qb-doc-scale { transform-origin: top left; }
    """
  end

  # Margin on the body, not the page, so the browser draws no header or footer.
  defp mode_rules(:print, page) do
    """
    @page { size: #{page.size}; margin: 0; }
    body {
      margin: 0;
      padding: 32px;
      background: #fff;
    }
    @media print {
      body { padding: #{page.margin}; }
      .qb-no-print { display: none !important; }
    }
    """
  end

  defp mode_rules(_screen, _page), do: ""

  # Whole-sheet options; empty at defaults, so stored layouts are unchanged.
  # Scoped to `--sheet`, which only the full document sets.
  defp sheet_rules(page) do
    border = Map.get(page, :border, "none")
    top = Map.get(page, :space_top, "0mm")
    bottom = Map.get(page, :space_bottom, "0mm")
    letterhead? = Map.get(page, :background, "") != ""

    rules =
      [
        border_rule(border),
        padding_rule(border, top, bottom),
        letterhead? && ".qb-doc--sheet.qb-doc--letterhead { aspect-ratio: #{aspect(page)}; }"
      ]
      |> Enum.filter(&is_binary/1)

    if rules == [], do: "", else: Enum.join(rules, "\n") <> "\n"
  end

  defp border_rule("hairline"),
    do: ".qb-doc--sheet { border: 1px solid var(--qb-rule); border-radius: 2px; }"

  defp border_rule("band"), do: ".qb-doc--sheet { border-top: 6px solid var(--qb-accent); }"
  defp border_rule(_none), do: nil

  defp padding_rule("none", "0mm", "0mm"), do: nil

  defp padding_rule(border, top, bottom) do
    {edge, inner} =
      case border do
        "hairline" -> {"24px", "24px"}
        "band" -> {"0px", "20px"}
        _none -> {"0px", "0px"}
      end

    ".qb-doc--sheet { padding: calc(#{inner} + #{space(top)}) #{edge} " <>
      "calc(#{if border == "hairline", do: inner, else: "0px"} + #{space(bottom)}); }"
  end

  # Closed enum in, literal out; anything else is no space at all.
  defp space(value) when value in ~w(0mm 20mm 35mm 50mm), do: value
  defp space(_value), do: "0mm"

  defp aspect(%{size: "Letter"}), do: "8.5 / 11"
  defp aspect(_a4), do: "210 / 297"

  # A letterhead prints edge to edge: the sheet takes the page margin as its own padding.
  defp letterhead_print(:print, %{background: "/" <> _} = page) do
    margin = page.margin

    """
    @media print {
      body { padding: 0; }
      .qb-doc--sheet.qb-doc--letterhead {
        max-width: none;
        min-height: 100vh;
        aspect-ratio: auto;
        padding: calc(#{margin} + #{space(page.space_top)}) #{margin} calc(#{margin} + #{space(page.space_bottom)});
      }
    }
    """
  end

  defp letterhead_print(_mode, _page), do: ""

  defp font_stack("serif") do
    ~s|ui-serif, Georgia, Cambria, "Times New Roman", Times, serif|
  end

  defp font_stack("mono") do
    ~s|ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace|
  end

  defp font_stack(_sans) do
    ~s|ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif|
  end

  # Every branch returns a literal; only the validated colour comes from the user.
  defp line_height(%{line_height: "tight"}), do: "1.3"
  defp line_height(%{line_height: "relaxed"}), do: "1.7"
  defp line_height(_page), do: "1.45"

  defp heading_weight(%{heading_weight: "medium"}), do: "500"
  defp heading_weight(%{heading_weight: "bold"}), do: "700"
  defp heading_weight(_page), do: "600"

  defp label_case(%{label_case: "normal"}), do: "none"
  defp label_case(_page), do: "uppercase"

  defp label_tracking(%{label_case: "normal"}), do: "0"
  defp label_tracking(_page), do: "0.08em"

  defp text_color(%{text_color: "#" <> _ = color}), do: color
  defp text_color(_page), do: "#18181b"

  defp label_color(%{label_color: "#" <> _ = color}), do: color
  defp label_color(_page), do: "#71717a"

  defp muted_color(%{muted_color: "#" <> _ = color}), do: color
  defp muted_color(_page), do: "#52525b"

  defp body_tracking(%{letter_spacing: "tight"}), do: "-0.01em"
  defp body_tracking(%{letter_spacing: "wide"}), do: "0.02em"
  defp body_tracking(_page), do: "normal"

  # Off by default to keep stored documents unchanged.
  defp numerals(%{numerals: "tabular"}), do: "tabular-nums"
  defp numerals(_page), do: "normal"

  defp block_gap(%{paragraph_spacing: "tight"}), do: "14px"
  defp block_gap(%{paragraph_spacing: "relaxed"}), do: "28px"
  defp block_gap(_page), do: "20px"

  defp head_padding(%{table_density: "compact"}), do: "4px 8px 4px 0"
  defp head_padding(%{table_density: "relaxed"}), do: "9px 8px 9px 0"
  defp head_padding(_page), do: "6px 8px 6px 0"

  defp cell_padding(%{table_density: "compact"}), do: "4px 8px 4px 0"
  defp cell_padding(%{table_density: "relaxed"}), do: "11px 8px 11px 0"
  defp cell_padding(_page), do: "7px 8px 7px 0"

  defp heading_size(%{heading_scale: "small"}, step) do
    case step do
      :sm -> "12px"
      :md -> "12px"
      :lg -> "13px"
    end
  end

  defp heading_size(%{heading_scale: "large"}, step) do
    case step do
      :sm -> "15px"
      :md -> "17px"
      :lg -> "19px"
    end
  end

  defp heading_size(_page, step) do
    case step do
      :sm -> "13px"
      :md -> "14px"
      :lg -> "15px"
    end
  end

  defp heading_stack(%{heading_font: face}) when face in ~w(sans serif mono),
    do: font_stack(face)

  defp heading_stack(page), do: font_stack(page.font)

  defp heading_color(%{heading_color: "accent"}), do: "var(--qb-accent)"
  defp heading_color(_page), do: "var(--qb-text)"
end
