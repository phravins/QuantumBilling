defmodule QuantumBillingWeb.InvoiceDoc.Stylesheet do
  @moduledoc """
  The invoice document's stylesheet, as a string.

  ## Why the document carries its own CSS

  The document is rendered on screen inside the application and again on a
  standalone print page that deliberately loads none of `app.css` — the mask
  based `hero-*` classes and the daisyUI theme are not available there, and an
  icon rendered through them came out blank on saved PDFs.

  The old answer was to write the markup twice, once in Tailwind and once in
  inline CSS, and keep a third module honest about what appeared in each. The
  answer here is that the print page cannot load *the application's* stylesheet,
  but it can load one the server hands it as a string. So can the LiveView. One
  markup, one stylesheet, injected in a `<style>` tag on whichever surface is
  rendering.

  ## Everything is scoped under `.qb-doc`

  This CSS lands in the middle of a Tailwind and daisyUI page, so every selector
  is prefixed. Nothing here can reach the application's chrome, and nothing in
  the application's stylesheet is relied on to be present. That scoping is what
  makes a `<style>` tag in the body harmless.

  The accent is not written into these rules. It arrives as the `--qb-accent`
  custom property, set inline on the `.qb-doc` element by the renderer, so the
  stylesheet stays static and the colour enters the page in exactly one place.
  """

  alias QuantumBillingWeb.InvoiceDoc.Document

  @doc """
  The stylesheet for `document`.

  ## Options

    * `:mode` — `:screen` (default) or `:print`. `:print` adds the paper rules;
      they are meaningless on screen and `@page` in particular would be a stray
      at-rule in the middle of an application page.
  """
  @spec css(Document.t(), keyword()) :: binary()
  def css(%Document{page: page}, opts \\ []) do
    base(page) <> mode_rules(Keyword.get(opts, :mode, :screen), page)
  end

  defp base(page) do
    """
    .qb-doc {
      --qb-accent: #18181b;
      --qb-rule: #e4e4e7;
      --qb-hairline: #f4f4f5;
      --qb-muted: #52525b;
      --qb-label: #71717a;
      max-width: 800px;
      margin: 0 auto;
      font-family: #{font_stack(page.font)};
      font-size: #{page.base_font}px;
      line-height: 1.45;
      color: #18181b;
      background: #fff;
    }
    .qb-doc *, .qb-doc *::before, .qb-doc *::after { box-sizing: border-box; }
    .qb-doc p, .qb-doc dl, .qb-doc dd, .qb-doc dt { margin: 0; }

    /* Blocks stack; the gap lives on the block so a removed one takes its
       spacing with it rather than leaving a hole. */
    .qb-doc__block { margin-top: 20px; }
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
      text-transform: uppercase;
      letter-spacing: 0.08em;
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
      font-weight: 600;
      letter-spacing: -0.01em;
      margin: 0 0 4px;
    }
    .qb-doc__heading--sm { font-size: 13px; }
    .qb-doc__heading--md { font-size: 14px; }
    .qb-doc__heading--lg { font-size: 15px; }
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
      text-transform: uppercase;
      letter-spacing: 0.08em;
      color: var(--qb-label);
      border-bottom: 1px solid var(--qb-rule);
      padding: 6px 8px 6px 0;
      white-space: nowrap;
    }
    .qb-doc__items td { padding: 7px 8px 7px 0; border-bottom: 1px solid var(--qb-hairline); }
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

  # `margin: 0` on the page leaves the browser nowhere to draw its own header
  # and footer, which is what was stamping the date, the page title and the
  # localhost URL onto saved PDFs. The margin moves onto the body instead.
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

  defp font_stack("serif") do
    ~s|ui-serif, Georgia, Cambria, "Times New Roman", Times, serif|
  end

  defp font_stack(_sans) do
    ~s|ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif|
  end
end
