# QuantumBilling

QuantumBilling is a Phoenix LiveView application for Indian business billing: clients, GST invoices, document templates, credit/debit notes, e-way bills, recurring billing, payment links, reports, and compliance reminders.

It uses Elixir, Phoenix, PostgreSQL, and Oban. Business data is being separated into PostgreSQL schemas, with shared accounts and business memberships in `public`.

## Documentation

All detailed guides live in [`docs/`](docs/README.md).

| Guide | Contents |
| --- | --- |
| [Getting started](docs/getting-started.md) | Local setup, migrations, seed account, login, troubleshooting |
| [Business guide](docs/Business.md) | Business ownership, roles, billing workflows, features, and limits |
| [Database structure](docs/database.md) | Public/business schemas, tables, relationships, money, indexes, migrations |
| [Technical architecture](docs/technical-architecture.md) | Supervision, requests, LiveViews, contexts, jobs, integrations, security |
| [Tech stack](docs/tech-stack.md) | Languages, dependency versions, tools, and their responsibilities |
| [Configuration](docs/configuration.md) | Environment variables, secrets, email, payments, and government portals |
| [Deployment and operations](docs/deployment.md) | Releases, migrations, storage, health, jobs, backup, recovery |
| [Development](docs/development.md) | Repository map, Mix commands, testing, and contribution conventions |

## Run locally

Use Elixir 1.18.3 / Erlang OTP 27, PostgreSQL 16, and Chromium for PDF generation. The project declares Elixir `~> 1.17`; see the [stack guide](docs/tech-stack.md).

Copy the template **only if `.env` does not already exist**:

```bash
cp .env.example .env
```

Set `DB_USERNAME` and `DB_PASSWORD` for PostgreSQL, and fill `SECRET_KEY_BASE`, `TOTP_ENCRYPTION_KEY`, and `SECRETS_ENCRYPTION_KEY`. Generate a separate value for each key with `openssl rand -base64 48`. Preserve encryption keys on an existing installation.

```bash
mix deps.get
mix ecto.create
mix ecto.migrate
mix assets.setup
mix assets.build
mix phx.server
```

Open [http://localhost:4000/users/log-in](http://localhost:4000/users/log-in). See the [setup guide](docs/getting-started.md) for registration and seeding.

`mix ecto.migrate` applies public migrations, then tenant migrations to every business schema. See the [database guide](docs/database.md) before migrating an existing installation.

## Seed login

There is no shared hardcoded password. Set these in your local `.env` before seeding:

```dotenv
SEED_ADMIN_EMAIL=demo@example.test
SEED_ADMIN_USERNAME=demo
SEED_ADMIN_PASSWORD=
```

Fill the password with your own value (8–72 characters). Login uses the configured **email and password**, not the username. Seeds confirm a newly created account directly and do not reset an existing password. The [setup guide](docs/getting-started.md#seed-account-and-login) gives the seed commands and rerun behavior.

## Checks and implementation status

```bash
mix test
mix precommit
```

This checkout contains business-schema changes: browser business selection, memberships, repository scoping, public links with business identity, and business-specific live updates. Run checks against your checkout before treating the setup as verified. [Architecture](docs/technical-architecture.md) and [Business](docs/Business.md) explain entry-point ownership and remaining workflow limits.

IRP and e-way-bill clients include simulated behavior, the HSN finder uses bundled data, and compliance calendars are not proof of tax filing. See the business guide for each workflow's limits.
