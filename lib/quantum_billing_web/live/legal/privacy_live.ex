defmodule QuantumBillingWeb.PrivacyLive do
  @moduledoc """
  Public Privacy Policy page, written for India's Digital Personal Data
  Protection Act 2023 and DPDP Rules 2025, with RBI payment rules where
  payments are involved.

  Keep it true to the code: retention periods, encryption and integrations
  described here match what the application actually does. Highlighted blanks
  are operator details still to be supplied. Not legal advice; have it reviewed.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.Legal.LegalComponents

  @effective_on ~D[2026-11-14]
  @updated_on ~D[2026-11-14]

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Privacy Policy",
       effective_on: @effective_on,
       updated_on: @updated_on
     )}
  end

  def render(assigns) do
    ~H"""
    <Layouts.legal
      flash={@flash}
      title="Privacy Policy"
      current_scope={@current_scope}
      other_doc_path={~p"/terms"}
      other_doc_label="Terms of Service"
      effective_on={@effective_on}
      updated_on={@updated_on}
      summary="How QuantumBilling collects, uses, stores and protects personal data, and the rights you have under India's Digital Personal Data Protection Act, 2023."
    >
      <.legal_section id="privacy-who-we-are" title="1. Who we are and what this policy covers">
        <p>
          QuantumBilling is a GST invoicing and compliance service operated by <.blank>registered legal entity name</.blank>,
          <.blank>registered address</.blank>
          ("we", "us"). This policy applies to our website, web application, API and related
          services (together, the "service").
        </p>

        <p>
          Under the Digital Personal Data Protection Act, 2023 (the "DPDP Act") we act in two
          different roles:
        </p>

        <.legal_list>
          <li>
            <strong>Data Fiduciary</strong>
            for the personal data of people who sign up for and use the service — account
            holders and their team members. We decide why and how that data is processed.
          </li>

          <li>
            <strong>Data Processor</strong>
            for the personal data a business enters about its own clients and customers, such as
            names, contact details and addresses on invoices. The business is the Data Fiduciary
            for that data and we process it only on its instructions.
          </li>
        </.legal_list>
      </.legal_section>

      <.legal_section id="privacy-data" title="2. Personal data we process">
        <.legal_list>
          <li>
            <strong>Account data</strong>
            — name, email address, password (stored only as a one-way hash), optional
            two-factor authentication settings, role within a business, and invitations.
          </li>

          <li>
            <strong>Business data</strong>
            — business name, GSTIN, PAN, registered and branch addresses, bank details printed
            on invoices, and the logo or letterhead you upload.
          </li>

          <li>
            <strong>Client and transaction data</strong>
            — the clients, invoices, credit notes, e-invoices, e-way bills, recurring profiles
            and amounts you create or import, which may include your customers' names, emails,
            phone numbers, addresses and GSTINs.
          </li>

          <li>
            <strong>Payment status data</strong>
            — where a business collects invoice payments through Razorpay, the order and payment
            reference numbers, amount, method type and status that Razorpay reports to us. See
            section 4.
          </li>

          <li>
            <strong>Integration credentials</strong>
            — credentials you provide for the Invoice Registration Portal, e-way bill system,
            your SMTP mail server and your Razorpay account. These are stored encrypted.
          </li>

          <li>
            <strong>Security and usage data</strong>
            — IP address, browser and device information on sign-in, sign-in history used for
            new-sign-in alerts, and an audit trail of actions taken inside a business.
          </li>

          <li>
            <strong>Calendar data</strong>
            — only if you connect Google Calendar: an access token and the filing-deadline events
            we create in your calendar.
          </li>

          <li>
            <strong>Communications</strong>
            — messages you send us for support, privacy requests or grievances.
          </li>
        </.legal_list>
      </.legal_section>

      <.legal_section id="privacy-purposes" title="3. Why we process it, and on what basis">
        <p>We process personal data only for these specified purposes:</p>

        <.legal_list>
          <li>creating and securing your account, including sign-in and two-factor checks;</li>
          <li>
            generating invoices, e-invoices (IRNs) and e-way bills, and filing them with
            government systems when you instruct us to;
          </li>
          <li>sending invoices, payment links, reminders and sign-in emails;</li>
          <li>recording payments reported by your payment gateway against your invoices;</li>
          <li>alerting you to unusual sign-ins and keeping an audit trail of changes;</li>
          <li>answering support requests and handling privacy requests and grievances;</li>
          <li>meeting our obligations under Indian law and responding to lawful orders.</li>
        </.legal_list>

        <p>
          We rely on your <strong>consent</strong> under Section 6 of the DPDP Act, given when you
          create an account or turn on a feature, and on <strong>legitimate uses</strong> under
          Section 7, such as complying with a law or a court order. You may withdraw consent at
          any time, as easily as you gave it (Section 6(4)), by disconnecting the feature or
          writing to us. Withdrawal does not affect processing already carried out, and
          withdrawing consent for core account data means we can no longer provide the service
          to you.
        </p>

        <p>
          We do not use personal data for advertising, we do not build marketing profiles, and
          we do not sell personal data to anyone.
        </p>
      </.legal_section>

      <.legal_section id="privacy-payments" title="4. Payments and RBI rules">
        <p>
          QuantumBilling does not process payments itself. A business can connect its own
          Razorpay account so that its customers can pay invoices online. Razorpay is a payment
          aggregator authorised by the Reserve Bank of India, and the payment takes place on
          Razorpay's checkout under its own terms and privacy policy.
        </p>

        <.legal_list>
          <li>
            We never receive or store card numbers, expiry dates, CVVs, UPI PINs or net-banking
            credentials. This is consistent with RBI's restriction on storing actual card data,
            under which card details are held only by card networks and issuers, using
            tokenisation.
          </li>

          <li>
            We store only the payment references and status Razorpay sends us, so the invoice can
            be marked as paid. Razorpay's notifications to us are stored encrypted.
          </li>

          <li>
            Payment system data held by Razorpay is governed by RBI's directions for payment
            aggregators, including the requirement to store it in India.
          </li>

          <li>
            Refunds, chargebacks and settlement are handled between the paying customer, the
            business and Razorpay.
          </li>
        </.legal_list>
      </.legal_section>

      <.legal_section id="privacy-sharing" title="5. Who we share personal data with">
        <p>We share personal data only as needed to run the service:</p>

        <.legal_list>
          <li>our hosting and infrastructure provider, with servers located in India;</li>

          <li>the email (SMTP) provider your business configures, to deliver its emails;</li>

          <li>Razorpay, where your business has connected it for payments;</li>

          <li>Google, only if you connect Google Calendar;</li>

          <li>
            government systems when you instruct us to file — the GST Network, the Invoice
            Registration Portal and the NIC e-way bill system;
          </li>

          <li>
            systems your business connects itself, through webhooks or API keys it creates;
          </li>

          <li>
            courts, regulators and law-enforcement agencies where Indian law requires it;
          </li>

          <li>
            a successor entity in a merger, acquisition or reorganisation, which must continue to
            protect the data under this policy.
          </li>
        </.legal_list>

        <p>
          Every service provider processes personal data only on our instructions and under a
          contract that requires reasonable security safeguards.
        </p>
      </.legal_section>

      <.legal_section id="privacy-location" title="6. Where your data is stored">
        <p>
          Personal data is stored and processed on servers in India. If we ever transfer
          personal data outside India, we will do so only to countries not restricted by the
          Central Government under Section 16 of the DPDP Act, update this policy before the
          transfer, and keep the same protections in place.
        </p>
      </.legal_section>

      <.legal_section id="privacy-retention" title="7. How long we keep it">
        <.legal_list>
          <li>
            <strong>Account, business, client and invoice data</strong>
            — for as long as your account is active. Items you delete go to the Bin, from which
            they can be restored until they are purged.
          </li>

          <li>
            <strong>Audit trail</strong>
            — 90 days by default; the business owner can change this period in settings.
          </li>

          <li>
            <strong>Email delivery logs, webhook records and notifications</strong> — 90 days.
          </li>

          <li>
            <strong>Sign-in sessions</strong> — expire after 14 days, or earlier when you sign out.
          </li>

          <li>
            <strong>After you close your account</strong>
            — we erase personal data within a reasonable time once its purpose is served, unless
            a law requires us to keep it longer, in which case we keep only what is required and
            only for as long as required.
          </li>
        </.legal_list>

        <p>
          Section 36 of the CGST Act, 2017 requires registered persons to keep their accounts and
          records for 72 months from the due date of the annual return. That obligation is your
          business's. Please use the exports in the service to keep your own copy before you
          delete data or close your account.
        </p>
      </.legal_section>

      <.legal_section id="privacy-security" title="8. How we protect it">
        <p>We use reasonable security safeguards, including:</p>

        <.legal_list>
          <li>encryption in transit (HTTPS/TLS) for all traffic;</li>
          <li>passwords, emailed sign-in links and API keys stored only as hashes;</li>
          <li>
            encryption at rest for integration credentials, two-factor secrets and payment
            notifications;
          </li>
          <li>optional two-factor authentication and alerts for new sign-ins;</li>
          <li>role-based access within each business, and an audit trail of changes;</li>
          <li>rate limiting and monitoring to resist abuse.</li>
        </.legal_list>

        <p>
          No system is completely secure. If a personal data breach occurs, we will inform the
          affected people and the Data Protection Board of India as required by Section 8(6) of
          the DPDP Act and the DPDP Rules, and report cyber security incidents to CERT-In within
          six hours as its directions require.
        </p>
      </.legal_section>

      <.legal_section id="privacy-rights" title="9. Your rights">
        <p>Under the DPDP Act you have the right to:</p>

        <.legal_list>
          <li>
            obtain a summary of your personal data we process and the processing activities,
            and the identities of those we have shared it with (Section 11);
          </li>
          <li>have your personal data corrected, completed, updated or erased (Section 12);</li>
          <li>have your grievances addressed by us (Section 13);</li>
          <li>
            nominate another person to exercise your rights if you die or become incapable
            (Section 14);
          </li>
          <li>withdraw consent you have given (Section 6).</li>
        </.legal_list>

        <p>
          To exercise a right, write to <.legal_email id="privacy-rights-email" /> from the email
          address on your account. We may need to verify your identity. We acknowledge requests
          within 24 hours and aim to resolve them within 15 days, and in any case within the
          period the DPDP Rules allow.
        </p>

        <p>
          If you are not satisfied with our response, you may complain to the Data Protection
          Board of India after using our grievance process (Section 13(3)).
        </p>

        <p>
          The DPDP Act also places duties on you (Section 15): provide accurate information, do
          not impersonate anyone, and do not file false or frivolous complaints.
        </p>
      </.legal_section>

      <.legal_section
        id="privacy-customers"
        title="10. If you are a customer of a business using QuantumBilling"
      >
        <p>
          If a business sent you an invoice or payment link through QuantumBilling, that business
          decides how your data is used. Please send requests about your data to the business
          first. If you contact us instead, we will pass your request to the business and help it
          respond.
        </p>
      </.legal_section>

      <.legal_section id="privacy-cookies" title="11. Cookies and browser storage">
        <p>
          We use only cookies that are strictly necessary: a session cookie that keeps you signed
          in and a security token that protects forms from cross-site request forgery. Your
          browser also stores a few display preferences, such as the colour theme and sidebar
          state. We do not use analytics, advertising or third-party tracking cookies. Blocking
          the necessary cookies will stop sign-in from working.
        </p>
      </.legal_section>

      <.legal_section id="privacy-children" title="12. Children">
        <p>
          The service is meant for businesses and for people aged 18 or over. We do not knowingly
          process the personal data of children, and we do not track, monitor behaviour of, or
          target advertising at children (Section 9). If you believe a child has created an
          account, write to us and we will delete it.
        </p>
      </.legal_section>

      <.legal_section id="privacy-law" title="13. Which laws apply">
        <p>
          The DPDP Act and the Digital Personal Data Protection Rules, 2025 are coming into force
          in phases, with most obligations applying from 13 May 2027. We follow them now as our
          standard. Until they fully apply, we also comply with Section 43A of the Information
          Technology Act, 2000 and the Information Technology (Reasonable Security Practices and
          Procedures and Sensitive Personal Data or Information) Rules, 2011.
        </p>
      </.legal_section>

      <.legal_section id="privacy-changes" title="14. Changes to this policy">
        <p>
          We will post any change on this page with a new "Last updated" date. If a change is
          material, we will tell you in the product or by email before it takes effect, and ask
          for fresh consent where the law requires it.
        </p>
      </.legal_section>

      <.legal_section id="privacy-contact" title="15. Contact and Grievance Officer">
        <p>
          For privacy questions, requests or grievances, contact our Grievance Officer:
        </p>

        <.legal_list>
          <li>
            Name:
            <.blank>grievance officer name</.blank>
          </li>
          <li>Email: <.legal_email id="privacy-contact-email" /></li>
          <li>
            Address:
            <.blank>registered address</.blank>
          </li>
        </.legal_list>
      </.legal_section>
    </Layouts.legal>
    """
  end
end
