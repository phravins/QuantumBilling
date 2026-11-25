<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/logo-dark.svg">
    <img src="docs/assets/logo-light.svg" alt="QuantumBilling" width="340">
  </picture>
</p>

<p align="center">
  <strong>Free, open-source GST billing for Indian businesses.</strong><br>
  Invoices, e-invoices, e-way bills and payment links, on a server you control.
</p>

<p align="center">
  <a href="https://osworks.in"><img src="docs/assets/osworks-mark.svg" alt="OSWORKS" width="40"></a><br>
  <sub>QuantumBilling is a community driven project under <a href="https://osworks.in"><strong>OSWORKS</strong></a>.</sub>
</p>

<p align="center">
  <a href="mix.exs"><img alt="Version v0.1.0" src="https://img.shields.io/badge/version-v0.1.0-111827"></a>
  <a href="LICENSE"><img alt="MIT licence" src="https://img.shields.io/badge/licence-MIT-111827"></a>
  <img alt="Elixir 1.18" src="https://img.shields.io/badge/Elixir-1.18-4B275F?logo=elixir&logoColor=white">
  <img alt="Phoenix 1.8" src="https://img.shields.io/badge/Phoenix-1.8-FD4F00">
  <img alt="PostgreSQL 16" src="https://img.shields.io/badge/PostgreSQL-16-336791?logo=postgresql&logoColor=white">
  <a href="#contributing"><img alt="Winter of Code Social 2026" src="https://img.shields.io/badge/Winter_of_Code_Social-2026-0E7490"></a>
</p>

<p align="center">
  <a href="#demo">Demo</a> ·
  <a href="#features">Features</a> ·
  <a href="#run-locally">Run locally</a> ·
  <a href="#documentation">Documentation</a> ·
  <a href="#contributing">Contributing</a>
</p>

![QuantumBilling dashboard: invoices issued, tax liability, receivables, GST by month, invoices by status, top clients and the compliance calendar](docs/assets/screenshots/dashboard.png)

## Demo

An 11-minute walkthrough: creating a business, filling in company details, and billing with QuantumBilling.

<p align="center">
  <a href="docs/assets/Video/QuantumBilling.mp4?raw=true">
    <img src="docs/assets/Video/QuantumBilling-poster.jpg" alt="Watch the QuantumBilling demo video (11 minutes)" width="720">
  </a>
</p>

## What is QuantumBilling?

QuantumBilling is a web application for sending invoices and staying on top of tax paperwork. It is built with Elixir and Phoenix LiveView.

With it, a business can:

- keep a list of its **clients**;
- raise **invoices** under India GST or VAT, and **credit and debit notes** against them;
- register invoices with the government's e-invoice portal (the IRP), which returns an **IRN**, the invoice's official reference number;
- raise **e-way bills**, the permits needed to move goods by road;
- bill customers automatically with **recurring invoices**;
- get paid through **payment links**;
- watch its numbers on a **dashboard**, export its data, and get **compliance reminders** before filing dates.

**Who it is for.** Small and medium businesses in India must issue GST-correct invoices, register e-invoices and raise e-way bills. QuantumBilling gives them a free, open-source way to do that on a server they control, with their records in their own database. Accountants who look after several businesses can run them all from one installation.

## Contents

- [How it works](#how-it-works)
- [At a glance](#at-a-glance)
- [Features](#features)
- [Screenshots](#screenshots)
- [Run locally](#run-locally)
- [Contributing](#contributing)
- [Deploy](#deploy)
- [Checks](#checks)
- [Documentation](#documentation)
- [Versions](#versions)
- [Current limits](#current-limits)
- [License](#license)

## How it works

- **One installation, many businesses.** Each business keeps its books in its own PostgreSQL schema (`biz_1`, `biz_2`, …). User accounts, memberships and background jobs are shared in the `public` schema.
- **One set of rules.** The web pages (Phoenix LiveView) and the REST API call the same business logic, so an invoice follows the same rules however it is created.
- **Background jobs.** Oban runs scheduled and slow work, such as recurring invoices, emails, e-invoice registration and nightly clean-up. It uses the same PostgreSQL database, so there is no separate queue service.
- **PDFs.** Invoices are printed to PDF by headless Chromium running on the server.

```mermaid
flowchart LR
  user["Browser"] --> app["Phoenix app<br/>LiveView pages + REST API"]
  api["API clients"] --> app
  app --> db[("PostgreSQL<br/>public + biz_1, biz_2, …")]
  app --> jobs["Oban jobs"]
  jobs --> db
  jobs --> ext["IRP e-invoice · NIC e-way bill<br/>Razorpay · SMTP email"]
  app --> pdf["Chromium<br/>invoice PDFs"]
```

## At a glance

| | |
| --- | --- |
| **Version** | **v0.1.0**, set by `version` in [`mix.exs`](mix.exs). See [Versions](#versions). |
| **Runtime** | Elixir 1.18.3 / Erlang OTP 27, Phoenix 1.8, LiveView 1.2, PostgreSQL 16, Oban 2.24 |
| **PDF output** | Headless Chromium (or Chrome) on the server |
| **API** | REST under `/api/v1` with scoped API keys. OpenAPI document 1.2.0 in [`docs/openapi.json`](docs/openapi.json) |
| **Deployment** | One OTP release behind a TLS reverse proxy. It runs the web app and the job queues, and needs no Redis or worker service. |
| **Licence** | [MIT](LICENSE) |

## Features

- **Invoicing.** Each business charges **India GST** (CGST/SGST/IGST from the place of supply) or **VAT** (UAE, Gulf states, UK, EU), and bills in INR, AED, SAR, QAR, GBP, EUR or USD. Invoices get numbered series, snapshots, statuses and a Bin with restore.
- **Adjustments.** Credit and debit notes follow the regime of their invoice.
- **India compliance.** IRP e-invoice registration, e-way bills (Form GST EWB-01 with Part-B legs), the GSTR-1 export (the monthly return of sales), an HSN/SAC finder for product and service codes, and a filing calendar with your own reminders.
- **Getting paid.** Email delivery with PDF, a public invoice page, and Razorpay payment links or a direct UPI QR, all for INR invoices.
- **Recurring billing.** Profiles generate invoices on a daily schedule.
- **Invoice designer.** Starting designs, layout blocks, letterheads, watermarks, payment details and printable custom fields.
- **Custom fields.** Eleven field types on clients, invoices, invoice lines, credit notes, e-way bills and recurring profiles. They can show as list columns or filters, print on invoices, and pass through the API.
- **Teams and security.** Owner and Staff roles, invitations, and optional TOTP two-factor authentication, which an owner can make mandatory for everyone. Also an audit trail, security alert emails, a nonce CSP and rate limits.
- **Integrations.** A REST API with idempotent writes, signed outgoing webhooks, and Google Calendar sync for compliance dates.
- **Data.** A dashboard with a sales register and tax-summary CSV exports, and a per-business JSON backup and restore.

> [!NOTE]
> Some integrations are simulated until you configure them. IRP registration runs in simulation by default, and e-way bills are demo numbers until `NIC_EWB_API_URL` is set. Both are labelled as demo wherever they appear. See [Current limits](#current-limits).

## Screenshots

| | |
| --- | --- |
| [![Invoice list with client, dates, total and status for each invoice](docs/assets/screenshots/invoices.png)](docs/assets/screenshots/invoices.png) | [![A paid GST tax invoice with its demo IRN banner](docs/assets/screenshots/invoice.png)](docs/assets/screenshots/invoice.png) |
| **Invoices.** Every invoice with its client, dates, total and status, plus search, a status filter and CSV export. | **Invoice.** A paid tax invoice. The banner marks its IRN as a demo, not registered with the IRP. |
| [![Invoice designer with typography and page controls, a live preview and page options](docs/assets/screenshots/designer.png)](docs/assets/screenshots/designer.png) | [![E-way bill list with route, value and status](docs/assets/screenshots/e-way-bills.png)](docs/assets/screenshots/e-way-bills.png) |
| **Invoice designer.** Type, spacing, page size, layout blocks, logo, frame, watermark and letterhead, with a live preview. | **E-way bills.** Bills raised from invoices, with route, value and status. The beaker marks a demo bill. |
| [![Client list with GSTIN, email, phone and outstanding amount](docs/assets/screenshots/clients.png)](docs/assets/screenshots/clients.png) | [![Recurring billing profiles with frequency, next run date and status](docs/assets/screenshots/recurring.png)](docs/assets/screenshots/recurring.png) |
| **Clients.** GSTIN, contact details and the outstanding amount for each client. | **Recurring billing.** Monthly, quarterly and annual profiles that raise invoices and email the PDF. |

Every page also has a dark theme, which follows the system setting or the choice in Settings → Preferences:

![The dashboard in the dark theme](docs/assets/screenshots/dashboard-dark.png)

The screenshots show release v0.1.0 with fictional demo data. The IRNs and e-way bill numbers in them are demo results, and nothing was filed.

## Run locally

### 1. Install the prerequisites

You need Elixir 1.18.3 / Erlang OTP 27, PostgreSQL 16, and Chromium for PDF generation. The project declares Elixir `~> 1.17`; the [stack guide](docs/tech-stack.md) explains the pinned versions.

### 2. Create your `.env` file

Copy the template **only if `.env` does not already exist**:

```bash
cp .env.example .env
```

In `.env`:

- Set `DB_USERNAME` and `DB_PASSWORD` for PostgreSQL.
- Fill `SECRET_KEY_BASE`, `TOTP_ENCRYPTION_KEY` and `SECRETS_ENCRYPTION_KEY`, generating a separate value for each with `openssl rand -base64 48`.
- On an existing installation, keep the encryption keys you already have.

### 3. Set up and start the app

```bash
mix deps.get       # download the Elixir dependencies
mix ecto.create    # create the database
mix ecto.migrate   # create the tables
mix assets.setup   # install the Tailwind and esbuild tools
mix assets.build   # build the CSS and JavaScript
mix phx.server     # start the app on port 4000
```

`mix ecto.migrate` applies the public migrations, then the tenant migrations to every business schema. Read the [database guide](docs/database.md) before you migrate an existing installation.

### 4. Sign in

Open [http://localhost:4000/users/log-in](http://localhost:4000/users/log-in). The [setup guide](docs/getting-started.md) covers registration and seeding.

### Seed login

No password is shared or hard-coded. Set these in your local `.env` before seeding:

```dotenv
SEED_ADMIN_EMAIL=demo@example.test
SEED_ADMIN_USERNAME=demo
SEED_ADMIN_PASSWORD=
```

Choose your own password (8–72 characters). Sign in with the **email and password**; the username is not used to sign in.

Seeding confirms a newly created account directly. It does not reset the password of an account that already exists. The [setup guide](docs/getting-started.md#seed-account-and-login) gives the seed commands and what happens when you rerun them.

## Contributing

QuantumBilling is part of **Winter of Code Social 2026**, and first-time contributors are welcome.

1. **Get the app running** with [Run locally](#run-locally) above.
2. **Read [CONTRIBUTING.md](CONTRIBUTING.md)**, especially the [Winter of Code Social section](CONTRIBUTING.md#winter-of-code-social-2026) and the [AI policy](CONTRIBUTING.md#ai-policy).
3. **Pick an issue:**
   - [Beginner issues (`level 1`)](https://github.com/phravins/QuantumBilling/issues?q=is%3Aissue+is%3Aopen+label%3A%22level+1%22)
   - [All open issues](https://github.com/phravins/QuantumBilling/issues)
4. **Comment on the issue to ask for it**, and start once it's assigned to you.

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md). If you change the UI, check it against the [accessibility checklist](ACCESSIBILITY.md#contributor-checklist).

Questions go in the QuantumBilling post in **#find-a-project** on the [Code Social Discord](https://discord.gg/MSTNyRSPYW). To report a security problem, follow [Reporting a vulnerability](CONTRIBUTING.md#reporting-a-vulnerability) instead of opening an issue.

## Deploy

QuantumBilling ships as an OTP release, a self-contained build of the app that runs on the server without Elixir installed. Build it with the same Elixir/OTP versions, on the same OS family as the server:

```bash
mix deps.get --only prod
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

On the server, set the environment, back up the database, run the migrations once, then start the release:

```bash
_build/prod/rel/quantum_billing/bin/migrate
_build/prod/rel/quantum_billing/bin/server
curl --fail http://localhost:4000/health     # {"status":"ok","database":"ok"}
```

| Variable | Needed | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | Yes | PostgreSQL connection URL |
| `PHX_HOST` | Yes | Public host name. It must match the address browsers use, or the LiveView socket is refused. |
| `SECRET_KEY_BASE` | Yes | Signs and encrypts sessions and tokens |
| `TOTP_ENCRYPTION_KEY` | Yes | Encrypts stored authenticator secrets |
| `SECRETS_ENCRYPTION_KEY` | Yes | Encrypts stored SMTP and provider secrets, and webhook payloads |
| `TRUSTED_PROXIES` | Behind a proxy | Proxy addresses allowed to supply the client IP |
| `DATABASE_SSL` | Remote database | `true` encrypts and verifies the database connection |
| `SMTP_*` | For mail | Confirmation, reset, invitation and invoice email. Production has no dev mailbox. |
| `PORT` | No (4000) | HTTP port. Reach it through the proxy only. |

Keep these in the host's secret manager or service environment, never in the repository or a file inside the release.

The proxy terminates TLS, overwrites `x-forwarded-proto` and `x-forwarded-for`, and passes the LiveView websocket through. The [deployment guide](docs/deployment.md) has example systemd and nginx configuration, host hardening, upgrades, backups and monitoring.

## Checks

Run these before you open a pull request:

```bash
mix test
mix precommit   # warnings as errors, drop unused locked deps, format, then the tests
```

## Documentation

Detailed guides live in [`docs/`](docs/README.md).

| Guide | Contents |
| --- | --- |
| [Getting started](docs/getting-started.md) | Local setup, migrations, seed account, login, troubleshooting |
| [Business guide](docs/Business.md) | Roles, settings, GST and VAT, custom fields, billing workflows, limits |
| [Configuration](docs/configuration.md) | Environment variables, secrets, email, payments, government portals |
| [Database structure](docs/database.md) | Public and business schemas, tables, money, indexes, migrations |
| [Technical architecture](docs/technical-architecture.md) | Supervision, requests, LiveViews, contexts, jobs, integrations, security |
| [Tech stack](docs/tech-stack.md) | Languages, dependency versions, tools and what each is for |
| [Development](docs/development.md) | Repository map, Mix commands, tests, contribution conventions |
| [Deployment and operations](docs/deployment.md) | Releases, versions, service setup, upgrades, health, jobs, backups |
| [API](docs/api.md) | Keys, scopes, endpoints, errors, idempotency ([OpenAPI](docs/openapi.json)) |
| [Webhooks](docs/webhooks.md) | Event catalogue, signatures, retries, secret rotation |
| [Accessibility](ACCESSIBILITY.md) | WCAG 2.2 AA target, what works, known gaps, how to report a problem |
| [Code of Conduct](CODE_OF_CONDUCT.md) | Expected behaviour and how to report a concern |

To propose a change or report a vulnerability, read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## Versions

| What | Current | Where it is set |
| --- | --- | --- |
| Application release | **v0.1.0** | `version` in [`mix.exs`](mix.exs). It also names the release's `lib/quantum_billing-0.1.0` directory. |
| REST API | `v1` paths, OpenAPI 1.2.0 | [`docs/openapi.json`](docs/openapi.json), versioned separately from the release |
| Business JSON backup | Format 3.0 | Restore also accepts 2.0 and 2.1 |

The README and the [docs index](docs/README.md) state the release version. `DocsVersionTest` fails if either stops matching `mix.exs`, so bump them together (including the version badge at the top of this file), and retake the screenshots in [`docs/assets/screenshots`](docs/assets/screenshots) when the screens change. The [deployment guide](docs/deployment.md#versions-and-upgrades) covers what a version change means on a server.

## Current limits

- **Demo portal results.** IRNs and e-way bills generated without a configured portal are demonstration data and are not filed. Settings → Integrations shows each portal's mode.
- **Bundled reference data.** The HSN data and compliance dates ship with the app, need independent upkeep, and do not prove that a return was filed.
- **No accounting ledgers.** There is no general ledger, purchase ITC, inventory or bank reconciliation, and no partial-payment ledger.
- **Limited VAT.** VAT covers invoicing, rates, credit notes and reports. It has no VAT return filing, no e-invoicing, and no currency conversion.

The [Business guide](docs/Business.md#18-current-implementation-limits) lists every limit.

## License

Released under the [MIT License](LICENSE). Copyright (c) 2026 phravins.

---

<p align="center">
  <a href="https://osworks.in"><img src="docs/assets/osworks-mark.svg" alt="OSWORKS" width="56"></a>
</p>

<p align="center">
  QuantumBilling is a community driven project under <a href="https://osworks.in"><strong>OSWORKS</strong></a>.<br>
  <a href="https://osworks.in">osworks.in</a>
</p>
