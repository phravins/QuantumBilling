# Configuration and credentials

The tracked template is [`.env.example`](../.env.example). Runtime behavior is defined in [`config/runtime.exs`](../config/runtime.exs), with integration-specific reads in the relevant clients. Actual credentials belong in `.env` locally or injected environment variables in a deployed release.

## Loading and precedence

Native Mix startup reads the repository's `.env` from runtime configuration. A nonblank real environment variable wins; a nonblank file value fills an unset or empty environment value. Blank file values are skipped. This loader supports one `KEY=value` per line, optional `export ` prefixes, full-line `#` comments, and matching single/double quotes around values. It does not perform shell variable substitution or inline-comment parsing. For example, do not append an explanatory comment to a password value.

`.env` and `.env.*` are Git-ignored except `.env.example`.

Restart the application after changing configuration. A production release uses variables injected by its service environment; do not assume the source checkout's `.env` exists on the production host.

## Required credentials and keys

| Variable | Required by | Purpose |
| --- | --- | --- |
| `DB_USERNAME` | Native development and tests | PostgreSQL user |
| `DB_PASSWORD` | Native development and tests | PostgreSQL password; no fallback credential |
| `SECRET_KEY_BASE` | Every environment | Endpoint cookie/token signing and encryption |
| `TOTP_ENCRYPTION_KEY` | Every environment | Encrypt stored authenticator secrets |
| `SECRETS_ENCRYPTION_KEY` | Every environment | Encrypt stored SMTP/provider secrets and webhook payloads |
| `DATABASE_URL` | Production runtime | Full Ecto PostgreSQL connection URL |
| `SEED_ADMIN_EMAIL` | Seeds only | Account lookup/creation and login email |
| `SEED_ADMIN_USERNAME` | Seeds only | Account username |
| `SEED_ADMIN_PASSWORD` | Seeds only | Initial password for a newly created seed account |

Runtime required variables reject absent and whitespace-only values. Generate each key independently with `mix phx.gen.secret` or `openssl rand -base64 48`. Preserve existing encryption keys across upgrades and recovery. Moving a key to environment configuration does not rotate it; previously committed values also remain in Git history until handled separately.

Seeds do not update an existing password. See [getting started](getting-started.md#seed-account-and-login) for account creation and the current business-context seed commands.

## Database, HTTP, and clustering

| Variable | Default when unset | Behavior |
| --- | --- | --- |
| `DB_HOSTNAME` | `localhost` | Native dev/test database host |
| `DB_PORT` | `5432` | Native dev/test database port, parsed as integer |
| `DB_NAME` | `quantum_billing_dev` | Development database |
| `DB_NAME_TEST` | `quantum_billing_test` | Test database |
| `MIX_TEST_PARTITION` | Empty suffix | Appended to the test database name only |
| `POOL_SIZE` | `20` in production | Shared Repo connection pool; dev/test pool settings are separate |
| `DB_QUEUE_TARGET_MS` | `150` in production | Database checkout queue target |
| `DB_QUEUE_INTERVAL_MS` | `1000` in production | Queue measurement interval |
| `DB_TIMEOUT_MS` | `15000` in production | Default query timeout |
| `ECTO_IPV6` | Disabled | `true` or `1` enables production IPv6 socket option |
| `PORT` | `4000` | Runtime HTTP listener |
| `PHX_HOST` | `example.com` in production | Host for generated production HTTPS URLs |
| `PHX_SERVER` | Unset | A present value enables endpoint server; release `bin/server` sets it |
| `DNS_CLUSTER_QUERY` | Unset | DNSCluster discovery query |
| `TRUSTED_PROXIES` | Empty | Comma-separated proxy IPs/CIDRs allowed to supply forwarded client IP |
| `SLOW_QUERY_MS` | `500` | Slow-query logging threshold |

Do not set `PHX_SERVER=false` to disable a server: the condition checks presence, not a boolean conversion. Leave it unset. Numeric values must be valid integer strings.

`DATABASE_URL` needs correctly encoded URL credentials: percent-encode reserved characters in the user and password. The production URL path is separate from native `DB_*` configuration.

## Email

Mail uses business SMTP settings when a usable relay is configured; otherwise it uses the application mailer. Development defaults to Swoosh's local adapter. Tests use the test adapter. Environment SMTP configuration replaces the development adapter when a host is supplied; production should have a working relay for account confirmation/reset and document mail.

| Variable | Default | Meaning |
| --- | --- | --- |
| `SMTP_HOST` | Unset | Fallback SMTP relay host |
| `SMTP_PORT` | `587` | Relay port |
| `SMTP_USERNAME` | Unset | Relay authentication username |
| `SMTP_PASSWORD` | Unset | Relay authentication password |
| `SMTP_SSL` | False unless port 465 | `true`/`1` requests implicit TLS; otherwise required STARTTLS |
| `SMTP_TLS_VERIFY` | Enabled | `false`/`0` disables certificate verification for a deliberately configured self-signed relay |
| `MAILER_FROM_EMAIL` | Settings/fallback sender logic | Fallback outgoing sender email |

Port 465 uses implicit TLS; other ports require STARTTLS. Verification normally checks the system trust store and relay hostname. SMTP credentials entered in settings are stored encrypted, and secret form fields do not render stored values. A blank secret input preserves the stored secret. Account mail is composed in `Accounts.UserNotifier`; invoice/e-way-bill mail has dedicated notifier modules and delivery records/jobs.

`Accounts.UserNotifier` selects the current business, or business 1 when there is none, for account mail transport and its ledger. Queued document mail (invoices, receipts, e-way bills) runs in the business that queued it, so it uses that business's SMTP settings and delivery ledger.

## Payments and UPI

| Variable | Default | Meaning |
| --- | --- | --- |
| `RAZORPAY_KEY_ID` | Unset | Fallback provider key ID; business settings take precedence |
| `RAZORPAY_KEY_SECRET` | Unset | Fallback provider secret; business settings take precedence |
| `RAZORPAY_SANDBOX` | Enabled in native dev/test; disabled in production | `true`/`1` permits simulated links, `false`/`0` disables them |
| `RAZORPAY_WEBHOOK_SECRET` | Unset | Verify incoming signatures; absent value causes deliveries to be rejected |

UPI VPA and payee name are business settings and are printed on invoice/payment documents. They are payment instructions, not authentication secrets. Simulated payment URLs do not establish payment collection. Incoming Razorpay requests go to `/api/webhooks/razorpay/:slug` for the named business; the legacy `/api/webhooks/razorpay` path selects business 1. The verification secret is currently installation-level. See [Business](Business.md) for status transitions and [architecture](technical-architecture.md) for validation.
## Government portal clients

| Variable | Default | Meaning |
| --- | --- | --- |
| `IRP_CLIENT_ID` | Unset | IRP request client ID |
| `IRP_CLIENT_SECRET` | Unset | IRP request secret |
| `IRP_SANDBOX` | `true` | `true`/`1` forces local simulation; missing credentials also select simulation |
| `IRP_API_URL` | `https://einv-apisandbox.nic.in` | Endpoint used by the live request branch |
| `IRP_GSTIN` | Compiled sample fallback | Used if an invoice has no company GSTIN; configure real business identity instead |
| `NIC_EWB_API_URL` | Unset | HTTP base URL for the NIC/GSP e-way-bill client |
| `NIC_EWB_API_KEY` | Empty | `x-api-key` header for that client |

`IRP_API_URL` and `IRP_GSTIN` are read by the client even though they are not listed in the starter template. The current IRP client reads its credentials from the environment; similarly named organization fields are not a complete credential-selection integration.

The NIC client generates demo bills when no suitable URL is set. With a URL set, a portal that does not answer properly is an error and nothing is recorded. Every IRN and e-way bill records whether it was demo or live and is labelled accordingly; Settings → Integrations shows the mode each portal is currently in. See [Business](Business.md) for data defaults and limitations.
## PDF and unused placeholders

| Variable | Behavior |
| --- | --- |
| `PDF_CHROME_PATH` | Browser executable; otherwise application config and common Chromium/Chrome names on `PATH` are checked |
| `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` | Template placeholders only; no GitHub sign-in route/provider flow is implemented |

Every environment that renders PDFs, production included, needs Chromium or Chrome installed. PDF rendering uses a temporary directory and a bounded subprocess; an unavailable renderer can lead to HTML attachments or an unavailable download action depending on the caller.

## Settings versus environment secrets

Environment configuration sets installation/runtime dependencies. Settings screens collect company details and optional business integrations. These mechanisms coexist: removing hardcoded source credentials does not remove the supported settings screens.

The public `installation_settings` model holds installation-wide IP, idle-timeout, and mandatory-two-factor policy, read by the browser security plug and session-expiry checks. The Security form displays these shared values and updates the public policy transactionally with business security fields; audit retention remains a business setting. Roles belong to business memberships, while passwords and two-factor enrolment belong to shared user accounts. See [database](database.md) for storage details and [Business](Business.md) for ownership boundaries.
