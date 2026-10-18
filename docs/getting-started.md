# Getting started

This guide covers local development, migrations, the seed account, and login. See [configuration](configuration.md) for environment variables and [database](database.md) for table ownership.

## How business data is laid out

Migrations keep each business's data in a `biz_<id>` schema; accounts and the business registry stay in `public`. Authenticated pages select a business through the session/picker, public links and callbacks name it by slug, and background jobs carry it in their arguments. A fresh database always has business 1 (`main`, `biz_1`), and the seed file writes into it. See [architecture](technical-architecture.md#multi-business-model) for how each entry point selects its business.

## Prerequisites

| Tool | Usage |
| --- | --- |
| Git | Obtain and update the source |
| Elixir / Erlang | Project requirement: Elixir `~> 1.17`; developed with Elixir 1.18.3 / OTP 27 |
| PostgreSQL | Use PostgreSQL 16; your local user must be able to create/migrate the configured dev/test databases |
| Chromium / Chrome | Generated PDFs; some delivery paths have an HTML fallback |
| OpenSSL | Secret generation; `mix phx.gen.secret` is another option |

Node.js is not required by the current asset workflow. Mix downloads standalone Tailwind and esbuild binaries. Check the tools selected by your shell:

```bash
elixir --version
mix --version
psql --version
```

## Native development setup

### 1. Configure `.env`

Run commands from the repository root. Copy the template only when `.env` does not already exist:

```bash
cp .env.example .env
```

Windows PowerShell equivalent:

```powershell
Copy-Item .env.example .env
```

Fill `DB_USERNAME` and `DB_PASSWORD` using your PostgreSQL credentials. Adjust `DB_HOSTNAME` and `DB_PORT` if the server is not at `localhost:5432`. `DB_NAME` and `DB_NAME_TEST` select separate databases.

Run this once for each of three distinct keys, then copy the output into the relevant variable:

```bash
openssl rand -base64 48
```

Set `SECRET_KEY_BASE`, `TOTP_ENCRYPTION_KEY`, and `SECRETS_ENCRYPTION_KEY`. All are required in development, tests, and production. Preserve existing keys during an upgrade: replacing encryption keys makes previously stored data unreadable.

For development preview emails, leave `SMTP_HOST` empty and clear any inherited `SMTP_HOST` environment variable. A configured relay replaces the local adapter in development. Tests retain the Swoosh test adapter.

### 2. Install dependencies

```bash
mix local.hex --force
mix local.rebar --force
mix deps.get
```

The first two commands install package tooling if missing. Fresh dependency/asset downloads require network access.

### 3. Create and migrate the database

```bash
mix ecto.create
mix ecto.migrate
```

The `ecto.migrate` alias applies public migrations first, then runs `quantum_billing.migrate_businesses` for each registered business, including archived businesses. The schema transition creates business 1 (`main`, `biz_1`) and moves existing business tables there. New installations follow the same path with empty tables.

PostgreSQL `pg_trgm` supports search indexes. The new-business baseline references its operator class, so the extension must be available before creating new business schemas. See [database prerequisites](database.md).

Use `mix ecto.migrate` again to apply later public and tenant changes.

### 4. Build assets

```bash
mix assets.setup
mix assets.build
```

The build compiles Elixir before bundling because assets import generated colocated hooks. There is no `npm install` step.

### 5. Start the server

```bash
mix phx.server
```

Interactive alternative:

```bash
iex -S mix phx.server
```

Open [http://localhost:4000](http://localhost:4000). `/health` checks the database. `/dev/mailbox` and `/dev/dashboard` are development-only tools. Restart after environment changes.

## Seed account and login

### Configure the seed account

Set the following in your local `.env` before running seeds:

```dotenv
SEED_ADMIN_EMAIL=demo@example.test
SEED_ADMIN_USERNAME=demo
SEED_ADMIN_PASSWORD=
```

Replace the example email/username if desired and fill the password yourself (8–72 characters). There is no committed shared password. The seed script validates all three variables before writing data and never prints the password.

### Seed business 1

After migration, run the seed file:

```bash
mix run priv/repo/seeds.exs
```

The script creates the sign-in account in `public`, then selects business 1 itself (`Repo.put_business(Businesses.default!())`) before writing its organization settings. `mix ecto.setup` and `mix setup` run the same file after migrating, so either path seeds business 1.

The script creates only the configured account and business 1's company settings (name, address, GSTIN, invoice prefix and starting number 1001). It adds no clients, invoices or other sample records; enter your own in the app, and replace the placeholder company details under Settings. On a fresh installation, the account receives owner membership in business 1 and is confirmed directly.

Reruns are not a reset operation: they write the company settings again, overwriting edits made in Settings, and reset the invoice counter only while business 1 has no invoices. A new email after initial registration may be rejected because subsequent accounts need invitations. Seeds do not replace an existing password or confirm an already existing unconfirmed account.

### Sign in

1. Open [http://localhost:4000/users/log-in](http://localhost:4000/users/log-in).
2. Enter `SEED_ADMIN_EMAIL` and the password you assigned to `SEED_ADMIN_PASSWORD`.
3. Complete two-factor verification if enabled.

Login uses email. Changing seed variables does not update an existing login. Use `/users/forgot-password` and the configured mail transport to reset an existing password.

## Register without seeding

After migration, an empty `users` table permits the first registration through `/users/register`. Enter a username, email, and password; confirm through the emailed link. With no SMTP override, development mail appears at `/dev/mailbox`. The first account receives owner membership in business 1. Further registrations require invitations; existing accounts can receive membership without a second login.

After login, a sole membership is selected automatically; with several memberships and no valid selection, business pages redirect to `/businesses`. Use `/businesses/new` to create a business and the picker/sidebar to switch. The switch is an authenticated POST that updates the browser session; connected tabs follow the selection.

Account emails use the selected business's relay and delivery ledger when there is a business context; signed-out registration/reset mail uses business 1. This fallback is implemented in `Accounts.UserNotifier` independently of browser business selection.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Missing/empty variable error | Set required credentials and all three keys; check shell overrides |
| PostgreSQL connection/authentication error | Check server status and native `DB_*` or production `DATABASE_URL` |
| `NoBusinessError` | Code queried a business table in a process with no business selected, such as a new `Task`, an IEx/`mix run` session, or a script; select one with `Repo.put_business/1` or `Repo.with_business/2` |
| Missing schema/table | Run `mix ecto.migrate`, which includes tenant migrations |
| `gin_trgm_ops` error | Ensure `pg_trgm` is available before new-business schema creation |
| No email in local mailbox | Settings/environment SMTP may be active; production has no preview mailbox |
| Seed password does not change login | Seeds preserve existing accounts; use password reset |
| PDF unavailable | Install Chromium/Chrome or set `PDF_CHROME_PATH` |
| Missing colocated asset import | Use `mix assets.build` / `mix assets.deploy`, which compile first |
| Port 4000 occupied | Set `PORT` |
| Business-related test failure | Check process business selection, scoped PubSub expectations, and schema-qualified raw SQL |

Continue with [development](development.md) for checks, or [deployment](deployment.md) for releases and recovery.
