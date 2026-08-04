defmodule QuantumBillingWeb.TermsLive do
  @moduledoc """
  Public Terms of Service page.

  The content below is an unreviewed template, not legal advice. It exists so
  the page, route and links are real; the wording must be replaced by
  lawyer-reviewed copy before publication.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.Legal.LegalComponents

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Terms of Service")}
  end

  def render(assigns) do
    ~H"""
    <Layouts.legal
      flash={@flash}
      title="Terms of Service"
      current_scope={@current_scope}
      other_doc_path={~p"/privacy"}
      other_doc_label="Privacy Policy"
    >
      <.legal_section title="1. Agreement to these terms">
        <p>
          These terms govern your use of QuantumBilling, a GST invoicing and compliance
          service operated by <.blank>registered legal entity name</.blank>,
          <.blank>registered address</.blank>
          ("we", "us"). By creating an account or using
          the service, you agree to these terms. If you are agreeing on behalf of a business,
          you confirm you are authorised to bind that business.
        </p>
      </.legal_section>

      <.legal_section title="2. The service">
        <p>
          QuantumBilling provides tools to create and manage GST invoices, generate e-invoices
          and e-way bills, track input tax credit, and monitor filing deadlines. Features may
          change over time as tax rules and our product evolve.
        </p>
      </.legal_section>

      <.legal_section title="3. Accounts and eligibility">
        <p>
          You must provide accurate registration details and keep your login credentials
          secure. You are responsible for all activity under your account. You must be at
          least 18 years old and legally able to enter into contracts.
        </p>
      </.legal_section>

      <.legal_section title="4. Your data and its accuracy">
        <p>
          You retain ownership of the business data you enter, including customer records,
          GSTINs, invoices and tax figures. You are solely responsible for the accuracy and
          completeness of that data and for the returns and filings you make using it. We
          process your data to provide the service, as described in our <.link
            navigate={~p"/privacy"}
            class="underline underline-offset-4 hover:text-base-content"
          >
            Privacy Policy
          </.link>.
        </p>
      </.legal_section>

      <.legal_section title="5. Not tax or legal advice">
        <p>
          QuantumBilling is software, not a tax advisor. Nothing in the service constitutes
          tax, accounting or legal advice, and calculations, reminders and compliance
          indicators are provided for convenience only. You remain responsible for meeting
          your obligations under the GST law and should consult a qualified professional.
        </p>
      </.legal_section>

      <.legal_section title="6. Fees and payment">
        <p>
          Paid plans are billed
          <.blank>billing frequency</.blank>
          in advance at the rates
          published at <.blank>pricing page URL</.blank>. Fees are exclusive of applicable
          taxes unless stated otherwise. Refund terms: <.blank>refund policy</.blank>.
          We may change pricing with
          <.blank>notice period</.blank>
          notice.
        </p>
      </.legal_section>

      <.legal_section title="7. Acceptable use">
        <p>You agree not to:</p>
        <.legal_list>
          <li>use the service to issue false, fraudulent or misleading tax documents;</li>
          <li>upload unlawful content or infringe anyone's rights;</li>
          <li>attempt to breach, probe or disrupt the service or its security;</li>
          <li>reverse engineer, resell or sublicense the service without our written consent;</li>
          <li>use automated means to place unreasonable load on the service.</li>
        </.legal_list>
      </.legal_section>

      <.legal_section title="8. Government portals and third-party services">
        <p>
          Certain features depend on third parties, including the GST Network, Invoice
          Registration Portals and e-way bill systems. We are not responsible for their
          availability, accuracy or downtime, and their own terms may apply to your use of
          them through our service.
        </p>
      </.legal_section>

      <.legal_section title="9. Availability and support">
        <p>
          We aim to keep the service available but do not guarantee uninterrupted access.
          Planned maintenance, updates and factors outside our control may cause downtime.
          Support is provided via <.blank>support channel and hours</.blank>. Any service
          level commitments are set out at <.blank>SLA URL, if offered</.blank>.
        </p>
      </.legal_section>

      <.legal_section title="10. Intellectual property">
        <p>
          The service, including its software, design and branding, remains our property.
          We grant you a limited, non-exclusive, non-transferable right to use it for your
          business while your account is active and fees are paid.
        </p>
      </.legal_section>

      <.legal_section title="11. Limitation of liability">
        <p>
          To the maximum extent permitted by law, we are not liable for indirect or
          consequential loss, loss of profits, or loss of data, and our total liability is
          limited to <.blank>liability cap, e.g. fees paid in the preceding 12 months</.blank>.
          Nothing here excludes liability that cannot lawfully be excluded.
        </p>
      </.legal_section>

      <.legal_section title="12. Suspension and termination">
        <p>
          You may stop using the service at any time. We may suspend or terminate access for
          breach of these terms, non-payment, or where required by law. On termination you may
          export your data for <.blank>export window</.blank>, after which it may be deleted
          in line with our retention policy.
        </p>
      </.legal_section>

      <.legal_section title="13. Changes to these terms">
        <p>
          We may update these terms. Material changes will be notified in the product or by
          email at least
          <.blank>notice period</.blank>
          before they take effect. Continuing to
          use the service after that constitutes acceptance.
        </p>
      </.legal_section>

      <.legal_section title="14. Governing law and disputes">
        <p>
          These terms are governed by the laws of India, and the courts at
          <.blank>city, state</.blank>
          have exclusive jurisdiction, subject to any
          dispute resolution process set out at <.blank>arbitration clause, if any</.blank>.
        </p>
      </.legal_section>

      <.legal_section title="15. Contact">
        <p>
          Questions about these terms can be sent to
          <.blank>legal contact email</.blank>
          or <.blank>registered address</.blank>.
        </p>
      </.legal_section>
    </Layouts.legal>
    """
  end
end
