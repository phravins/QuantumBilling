defmodule QuantumBillingWeb.PrivacyLive do
  @moduledoc """
  Public Privacy Policy page.

  The content below is an unreviewed template, not legal advice. Data
  protection obligations vary by jurisdiction; have this reviewed and completed
  before publication.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.Legal.LegalComponents

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Privacy Policy")}
  end

  def render(assigns) do
    ~H"""
    <Layouts.legal
      flash={@flash}
      title="Privacy Policy"
      current_scope={@current_scope}
      other_doc_path={~p"/terms"}
      other_doc_label="Terms of Service"
    >
      <.legal_section title="1. Overview">
        <p>
          This policy explains how
          <.blank>registered legal entity name</.blank>
          ("we")
          collects and handles personal data when you use QuantumBilling. It covers our
          website, application and related services.
        </p>
      </.legal_section>

      <.legal_section title="2. Information we collect">
        <.legal_list>
          <li>
            <strong>Account data</strong> — name, email address and authentication records
            such as login tokens.
          </li>

          <li>
            <strong>Business data</strong> — your GSTIN, business name, registered address
            and tax registration details.
          </li>

          <li>
            <strong>Customer and transaction data</strong> — the client records, invoices,
            e-way bills and amounts you enter into the service.
          </li>

          <li>
            <strong>Technical data</strong> — IP address, browser and device information,
            and log records of how the service is used.
          </li>

          <li>
            <strong>Billing data</strong> — plan and payment records, handled by our payment
            processor <.blank>payment processor</.blank>.
          </li>
        </.legal_list>
      </.legal_section>

      <.legal_section title="3. How we use information">
        <.legal_list>
          <li>to provide, operate and secure the service;</li>

          <li>to generate invoices, e-invoices and e-way bills on your instruction;</li>

          <li>to send transactional messages such as sign-in links and filing reminders;</li>

          <li>to provide support and respond to your requests;</li>

          <li>to detect fraud and abuse, and to meet legal obligations;</li>

          <li>to analyse and improve the service in aggregate form.</li>
        </.legal_list>
      </.legal_section>

      <.legal_section title="4. Legal basis for processing">
        <p>
          Where applicable law requires a legal basis, we rely on performance of our contract
          with you, our legitimate interests in operating and securing the service, your
          consent where requested, and compliance with legal obligations. Applicable
          framework: <.blank>e.g. India's DPDP Act 2023, GDPR where relevant</.blank>.
        </p>
      </.legal_section>

      <.legal_section title="5. Sharing and disclosure">
        <p>We do not sell your personal data. We share it only with:</p>

        <.legal_list>
          <li>
            service providers who host and support the platform, such as <.blank>hosting provider</.blank>,
            <.blank>email provider</.blank>
            and <.blank>payment processor</.blank>;
          </li>

          <li>
            government systems where you instruct us to file, including the GST Network,
            Invoice Registration Portals and e-way bill systems;
          </li>

          <li>authorities where disclosure is legally required;</li>

          <li>a successor entity in a merger or acquisition, subject to this policy.</li>
        </.legal_list>
      </.legal_section>

      <.legal_section title="6. Data retention">
        <p>
          We keep account and transaction data for as long as your account is active and
          afterwards where required for tax, accounting or legal purposes. Note that GST
          records are generally subject to statutory retention periods; our retention schedule
          is <.blank>retention period per data category</.blank>. Backups are cleared on a
          <.blank>backup rotation period</.blank>
          cycle.
        </p>
      </.legal_section>

      <.legal_section title="7. Security">
        <p>
          We use technical and organisational measures including encryption in transit,
          hashed authentication tokens and access controls. Passwords, where set, are stored
          only as cryptographic hashes. No system is completely secure, so we cannot guarantee
          absolute security. Breach notification process: <.blank>notification process and
          timeline</.blank>.
        </p>
      </.legal_section>

      <.legal_section title="8. Your rights">
        <p>
          Subject to applicable law, you may request access to, correction of, or deletion of
          your personal data, object to or restrict certain processing, withdraw consent, and
          request a portable copy. To exercise these rights contact <.blank>privacy contact email</.blank>. We respond within <.blank>response window</.blank>.
        </p>
      </.legal_section>

      <.legal_section title="9. Cookies and similar technologies">
        <p>
          We use cookies that are necessary to keep you signed in and to secure the service,
          and <.blank>analytics or other optional cookies, if any</.blank>. You can control
          cookies through your browser, though disabling essential cookies will prevent
          sign-in from working.
        </p>
      </.legal_section>

      <.legal_section title="10. International transfers">
        <p>
          Your data is primarily stored in <.blank>hosting region</.blank>. Where data is
          transferred outside that region, we rely on
          <.blank>transfer safeguards</.blank>
          to protect it.
        </p>
      </.legal_section>

      <.legal_section title="11. Children's data">
        <p>
          The service is intended for businesses and is not directed at children. We do not
          knowingly collect data from anyone under 18.
        </p>
      </.legal_section>

      <.legal_section title="12. Changes to this policy">
        <p>
          We may update this policy and will post the revised version here. Material changes
          will be notified in the product or by email before they take effect.
        </p>
      </.legal_section>

      <.legal_section title="13. Contact and grievances">
        <p>
          For privacy questions contact <.blank>privacy contact email</.blank>. Our
          Grievance Officer, required under India's information technology rules, is <.blank>grievance officer name</.blank>, reachable at <.blank>grievance officer email</.blank>, <.blank>registered address</.blank>.
        </p>
      </.legal_section>
    </Layouts.legal>
    """
  end
end
