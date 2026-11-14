defmodule QuantumBillingWeb.TermsLive do
  @moduledoc """
  Public Terms of Service page, written for Indian law: the Indian Contract Act,
  the Information Technology Act, GST law and RBI payment rules.

  Highlighted blanks are operator details still to be supplied. Not legal
  advice; have it reviewed before relying on it.
  """
  use QuantumBillingWeb, :live_view

  import QuantumBillingWeb.Legal.LegalComponents

  @effective_on ~D[2026-11-14]
  @updated_on ~D[2026-11-14]

  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Terms of Service",
       effective_on: @effective_on,
       updated_on: @updated_on
     )}
  end

  def render(assigns) do
    ~H"""
    <Layouts.legal
      flash={@flash}
      title="Terms of Service"
      current_scope={@current_scope}
      other_doc_path={~p"/privacy"}
      other_doc_label="Privacy Policy"
      effective_on={@effective_on}
      updated_on={@updated_on}
      summary="The agreement between you and us for using QuantumBilling: what the service does, what each of us is responsible for, and how disputes are resolved under Indian law."
    >
      <.legal_section id="terms-agreement" title="1. Agreement to these terms">
        <p>
          These terms are an agreement between you and <.blank>registered legal entity name</.blank>,
          <.blank>registered address</.blank>
          ("we", "us"), the operator of QuantumBilling.
          By creating an account or using the service you accept these terms and our <.link
            navigate={~p"/privacy"}
            class="underline underline-offset-4 hover:text-base-content"
          >Privacy Policy</.link>.
        </p>

        <p>
          These terms are an electronic record under the Information Technology Act, 2000 and
          form a valid contract without a physical signature (Section 10A). If you accept them
          on behalf of a business, you confirm that you are authorised to bind that business,
          and "you" means the business as well as you.
        </p>
      </.legal_section>

      <.legal_section id="terms-service" title="2. The service">
        <p>
          QuantumBilling is software for Indian businesses to create GST invoices and credit
          notes, generate e-invoices (IRNs) and e-way bills, manage clients and recurring
          invoices, collect payments through a payment gateway you connect, and track filing
          deadlines. We may add, change or remove features as tax rules and the product evolve,
          and will give notice of changes that materially reduce what the service does.
        </p>
      </.legal_section>

      <.legal_section id="terms-accounts" title="3. Eligibility and accounts">
        <.legal_list>
          <li>
            You must be at least 18 and competent to contract under the Indian Contract Act,
            1872.
          </li>

          <li>
            Give accurate registration details and keep them up to date.
          </li>

          <li>
            Keep your password and sign-in links confidential. We recommend turning on
            two-factor authentication.
          </li>

          <li>
            The account owner is responsible for the team members they invite and the roles they
            give them, and for all activity under the business's account.
          </li>

          <li>
            Tell us at once at <.legal_email id="terms-accounts-email" />
            if you suspect unauthorised access.
          </li>
        </.legal_list>
      </.legal_section>

      <.legal_section id="terms-data" title="4. Your data and your data protection duties">
        <p>
          You own the data you put into the service. You give us permission to host, process and
          transmit it only as needed to provide the service to you, as described in our Privacy
          Policy.
        </p>

        <p>
          For the personal data of your own clients and customers, you are the Data Fiduciary
          under the Digital Personal Data Protection Act, 2023 and we are your Data Processor.
          You are responsible for having a lawful basis to use that data, giving your customers
          any notice the law requires, and answering their requests. We will process it only on
          your instructions and help you respond to their requests where we reasonably can.
        </p>
      </.legal_section>

      <.legal_section id="terms-gst" title="5. GST compliance remains your responsibility">
        <p>
          QuantumBilling is software, not a tax practitioner. Nothing in the service is tax,
          accounting or legal advice, and tax calculations, HSN/SAC suggestions, compliance
          indicators and reminders are aids only.
        </p>

        <.legal_list>
          <li>
            You are responsible for the accuracy of GSTINs, place of supply, HSN/SAC codes, tax
            rates, invoice values, e-invoices and e-way bills issued through your account, and for
            your returns under the GST laws.
          </li>

          <li>
            You must keep your own accounts and records for the period required by Section 36 of
            the CGST Act, 2017. Use the exports in the service to keep copies.
          </li>

          <li>
            The GST Network, Invoice Registration Portals and the NIC e-way bill system are run by
            government bodies. We are not responsible for their outages, rejections or changes.
          </li>
        </.legal_list>
      </.legal_section>

      <.legal_section id="terms-payments" title="6. Collecting payments through Razorpay">
        <p>
          You can connect your own Razorpay account so customers can pay your invoices online.
          Razorpay is a payment aggregator authorised by the Reserve Bank of India.
        </p>

        <.legal_list>
          <li>
            Your agreement with Razorpay, and the RBI rules that apply to it, govern those
            payments, including KYC, settlement, refunds, chargebacks and disputes.
          </li>

          <li>
            We never hold, receive or move funds, and we are not a payment system operator under
            the Payment and Settlement Systems Act, 2007. Money moves directly between your
            customer, Razorpay and your bank account.
          </li>

          <li>
            We never store card, UPI or net-banking credentials. We record only the payment
            reference and status Razorpay reports, to mark your invoice as paid.
          </li>

          <li>
            You are responsible for keeping your Razorpay keys secure and for refunds to your own
            customers.
          </li>
        </.legal_list>
      </.legal_section>

      <.legal_section id="terms-fees" title="7. Fees">
        <p>
          The service is currently free of charge. If we introduce paid plans:
        </p>

        <.legal_list>
          <li>
            we will give at least 30 days' notice, and you will not be charged unless you choose a
            paid plan;
          </li>

          <li>prices will be in Indian rupees, with GST shown separately on a tax invoice;</li>

          <li>
            any recurring charge to a card or UPI will follow RBI's e-mandate framework, including
            additional authentication when you set it up and a pre-debit notification at least
            24 hours before each charge, and you will be able to cancel it at any time.
          </li>
        </.legal_list>
      </.legal_section>

      <.legal_section id="terms-acceptable-use" title="8. Acceptable use">
        <p>You agree not to:</p>

        <.legal_list>
          <li>
            issue invoices without an actual supply of goods or services, or use the service for
            fake invoicing, circular trading or wrongful input tax credit, which are offences under
            Section 122 of the CGST Act, 2017;
          </li>

          <li>
            upload content that is unlawful, infringes anyone's rights, or contains malware;
          </li>

          <li>
            access another business's data, probe or break our security, or bypass rate limits;
          </li>

          <li>
            scrape, overload, copy, reverse engineer, resell or sublicense the service without our
            written consent;
          </li>

          <li>use the service in breach of the Information Technology Act, 2000 or any other law.</li>
        </.legal_list>
      </.legal_section>

      <.legal_section id="terms-third-parties" title="9. Third-party services">
        <p>
          Some features depend on services we do not control: the GST Network, Invoice
          Registration Portals, the NIC e-way bill system, Razorpay, Google Calendar and the email
          provider you configure. Their own terms apply to your use of them, and we are not
          responsible for their availability or actions.
        </p>
      </.legal_section>

      <.legal_section id="terms-availability" title="10. Availability and support">
        <p>
          We aim to keep the service available and your data safe, but we do not guarantee
          uninterrupted or error-free operation. Maintenance, updates and events outside our
          control may cause downtime. While the service is free it is provided "as is". Support is
          available at <.legal_email id="terms-support-email" />.
        </p>
      </.legal_section>

      <.legal_section id="terms-ip" title="11. Intellectual property">
        <p>
          The service, including its software, design and branding, belongs to us. We grant you a
          limited, non-exclusive, non-transferable, revocable right to use it for your business
          while these terms apply. If you send us feedback, we may use it without obligation to
          you.
        </p>
      </.legal_section>

      <.legal_section id="terms-confidentiality" title="12. Confidentiality and security">
        <p>
          We treat your business data as confidential and protect it with reasonable security
          practices, as described in our Privacy Policy. We will not access it except to provide
          the service, give support you ask for, keep the service secure, or comply with law.
        </p>
      </.legal_section>

      <.legal_section id="terms-liability" title="13. Disclaimers and limitation of liability">
        <p>To the maximum extent permitted by law:</p>

        <.legal_list>
          <li>
            we are not liable for indirect, incidental or consequential loss, loss of profits,
            business or goodwill, or for tax, interest, penalties or input tax credit lost because
            of data you entered or filings you made;
          </li>

          <li>
            our total liability for all claims relating to the service is limited to the fees you
            paid us in the 12 months before the claim arose.
          </li>
        </.legal_list>

        <p>Nothing in these terms excludes liability that cannot lawfully be excluded.</p>
      </.legal_section>

      <.legal_section id="terms-indemnity" title="14. Indemnity">
        <p>
          You will indemnify us against claims, penalties and costs arising from the data you put
          into the service, the invoices and filings you issue, your dealings with your customers,
          or your breach of these terms or the law.
        </p>
      </.legal_section>

      <.legal_section id="terms-termination" title="15. Suspension and termination">
        <p>
          You may stop using the service at any time and ask us to close your account. We may
          suspend or terminate access, with notice where practical, for breach of these terms,
          suspected fraud or misuse, or where the law requires it.
        </p>

        <p>
          After termination you will have 30 days to export your data, unless the law prevents it.
          After that we delete it as described in our Privacy Policy. Sections 4, 5, 6, 11, 13, 14
          and 17 continue to apply after termination.
        </p>
      </.legal_section>

      <.legal_section id="terms-changes" title="16. Changes to these terms">
        <p>
          We may update these terms. We will post changes on this page with a new "Last updated"
          date and give at least 30 days' notice of material changes in the product or by email.
          If you keep using the service after a change takes effect, you accept the updated terms.
        </p>
      </.legal_section>

      <.legal_section id="terms-disputes" title="17. Governing law and disputes">
        <p>These terms are governed by the laws of India.</p>

        <.legal_list>
          <li>
            Before starting any proceedings, write to us and give us 30 days to resolve the dispute
            in good faith.
          </li>

          <li>
            Disputes that remain unresolved will be settled by arbitration under the Arbitration and
            Conciliation Act, 1996, by a sole arbitrator appointed by mutual agreement. The seat of
            arbitration will be
            <.blank>city, state</.blank>
            and proceedings will be in English.
          </li>

          <li>
            Subject to arbitration, the courts at
            <.blank>city, state</.blank>
            have exclusive jurisdiction, including for urgent interim relief.
          </li>
        </.legal_list>
      </.legal_section>

      <.legal_section id="terms-grievances" title="18. Grievances and contact">
        <p>
          Send questions or complaints about the service or these terms to our Grievance Officer at
          <.legal_email id="terms-contact-email" />
          or <.blank>registered address</.blank>. We acknowledge
          complaints within 24 hours and aim to resolve them within 15 days.
        </p>
      </.legal_section>

      <.legal_section id="terms-general" title="19. General">
        <.legal_list>
          <li>
            These terms and the Privacy Policy are the entire agreement between you and us about
            the service.
          </li>

          <li>If any provision is held invalid, the rest of the terms remain in force.</li>

          <li>Failing to enforce a right is not a waiver of it.</li>

          <li>
            You may not transfer these terms without our consent; we may transfer them to a
            successor in a merger, acquisition or reorganisation.
          </li>

          <li>
            Neither party is liable for delay caused by events beyond its reasonable control, such
            as outages of government portals, network failures or natural disasters.
          </li>
        </.legal_list>
      </.legal_section>
    </Layouts.legal>
    """
  end
end
