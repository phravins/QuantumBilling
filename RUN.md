# Running QuantumBilling Locally

This guide covers running **QuantumBilling** on your local machine, either using **Docker Compose** (recommended for zero-dependency startup) or directly via **Elixir & PostgreSQL**.

---

## Option 1: Running with Docker Compose (Recommended)

Docker Compose sets up both the PostgreSQL 17 database and the QuantumBilling Phoenix application with a single command.

### Prerequisites
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) installed and running.

### Steps

1. **Clone the repository** (if not already cloned):
   ```bash
   git clone https://github.com/phravins/QuantumBilling.git
   cd QuantumBilling
   ```

2. **Start the application and database**:
   ```bash
   docker compose up --build
   ```

3. **Access the Application**:
   - Open your browser at: [http://localhost:4000](http://localhost:4000)
   - Database migrations will execute automatically on container startup.

4. **Stop the containers**:
   ```bash
   docker compose down
   ```
   *(Add `-v` to reset the database volume: `docker compose down -v`)*

---

## Option 2: Running Directly on Your Machine

### Prerequisites
- **Elixir**: version 1.17 or later ([Install Elixir](https://elixir-lang.org/install.html))
- **Erlang/OTP**: version 26, 27, or 28/29
- **PostgreSQL**: version 14 or later (running locally on port `5432`)
- **Node.js** (optional; Phoenix manages Esbuild and Tailwind standalone executables automatically)

---

### Step-by-Step Native Setup

#### 1. Configure Environment Variables
Copy the template environment file to `.env`:

```bash
# On Linux / macOS / Git Bash:
cp .env.example .env

# On Windows PowerShell:
Copy-Item .env.example .env
```

Ensure the database credentials in `.env` match your local PostgreSQL service:
```ini
DB_USERNAME=postgres
DB_PASSWORD=postgres
DB_HOSTNAME=localhost
DB_PORT=5432
DB_NAME=quantum_billing_dev
DB_NAME_TEST=quantum_billing_test
```

#### 2. Install Dependencies
Download and compile all required Elixir and Phoenix packages:
```bash
mix deps.get
```

#### 3. Setup the Database
Create the database and run all Ecto migrations:
```bash
mix ecto.setup
```
*Note: If the database is already created, you can run `mix ecto.migrate` to apply pending migrations.*

#### 4. Setup and Build Frontend Assets
Install and compile Tailwind CSS v4 and DaisyUI:
```bash
mix assets.setup
mix assets.build
```

#### 5. Start the Phoenix Server
Launch the development web server:
```bash
mix phx.server
```
*(Or start interactively inside the Elixir shell with `iex -S mix phx.server`)*

Open your browser at [http://localhost:4000](http://localhost:4000).

---

## First-Time User Registration & Email Confirmation

Because demo administrator passwords are not hardcoded into the codebase for security reasons, follow these steps to create your initial user:

1. Visit [http://localhost:4000/users/register](http://localhost:4000/users/register)
2. Enter your email and password, then submit the registration form.
3. QuantumBilling will send a local confirmation email through Swoosh.
4. Open the local development mailbox at [http://localhost:4000/dev/mailbox](http://localhost:4000/dev/mailbox).
5. Click the confirmation link in the received email.
6. You are now verified and logged in!

---

## Running Automated Tests & Precommit Audits

To verify that all features, tax rules, and security protections are functioning properly:

- **Run the full test suite (891 tests)**:
  ```bash
  mix test
  ```

- **Run the project precommit check** (verifies zero warnings, code formatting, and all tests):
  ```bash
  mix precommit
  ```

- **Run security dependency audit**:
  ```bash
  mix hex.audit
  ```

---

## Background Jobs

Anything slow, failure-prone, or too important to lose runs as an
[Oban](https://hexdocs.pm/oban) job in Postgres rather than inside the request
that asked for it: sending invoices, registering them with the IRP, billing
recurring profiles, posting outbound webhooks, and pruning the audit trail.

Queues (see `config/config.exs`): `mailers`, `webhooks`, `recurring`,
`maintenance`, `default`. Jobs survive restarts, are retried with backoff, and
can be inspected in the `oban_jobs` table:

```sql
-- What is waiting, and what has given up
SELECT state, queue, worker, count(*) FROM oban_jobs GROUP BY 1, 2, 3;

-- Why a job failed
SELECT worker, args, errors FROM oban_jobs WHERE state = 'discarded';
```

Scheduled work is inserted by the Cron plugin on the Oban leader — one node,
however many are running:

| When (UTC) | Job | What it does |
| --- | --- | --- |
| 01:30 daily | `RecurringInvoiceWorker` | Queues one billing job per due recurring profile |
| 02:00 daily | `AuditPruneWorker` | Deletes audit logs past the retention window, and mail/webhook ledgers past 90 days |

Email delivery is visible in the application itself, under
**Settings → SMTP → Recent Deliveries**: every attempt, its status, and the
relay's own error message if it failed.

---

## Security Notes

- **Secrets at rest.** The SMTP password, Razorpay key secret, IRP password and
  webhook signing secret are encrypted with AES-256-GCM under
  `SECRETS_ENCRYPTION_KEY`; TOTP secrets under `TOTP_ENCRYPTION_KEY`. Both are
  required in production and the app refuses to boot without them. The settings
  form is write-only for credentials — it never renders a stored one back.
- **Incoming webhooks.** `/api/webhooks/razorpay` requires a valid signature
  over the raw request body, keyed with `RAZORPAY_WEBHOOK_SECRET`. Without that
  variable set, the endpoint refuses every delivery. Events are recorded by id
  so a redelivery cannot mark an invoice paid twice.
- **Outgoing webhooks.** Signed with HMAC-SHA256 in the
  `x-quantumbilling-signature` header, using the secret from
  Settings → Integrations.
- **Behind a proxy.** `x-forwarded-for` is only believed from addresses listed
  in `TRUSTED_PROXIES`. Leave it empty when the app is reached directly, or the
  IP allowlist and per-address rate limiting can be bypassed with a header.
- **Mail in transit.** Relay certificates are verified against the system trust
  store and the hostname; STARTTLS is required on anything but port 465. Set
  `SMTP_TLS_VERIFY=false` only for a self-signed relay on a trusted network.

---

## Troubleshooting & Common Questions

### PostgreSQL Connection Refused
- Ensure your PostgreSQL service is running:
  - **Windows**: Check `Get-Service *postgres*` or open Services and start PostgreSQL.
  - **Linux/macOS**: `sudo systemctl status postgresql` or `brew services list`.
- Check username/password in `.env` match your local database installation.

### Port 4000 Already in Use
- Change `PORT=4001` in your `.env` or run:
  ```bash
  PORT=4001 mix phx.server
  ```

### "You must restart your server after changing configuration files"
- If you edit `.env` or files under `config/`, stop the server process (`Ctrl + C` twice) and start it again with `mix phx.server`.

### Invoice emails are not arriving
1. Open **Settings → SMTP** and press **Send Test Email**. The flash message is
   the relay's own answer, not a generic failure.
2. Check **Recent Deliveries** on the same panel: a message stuck at `queued`
   with a rising attempt count is being retried; `failed` means Oban has given
   up, and the last error is shown.
3. A host, a username and a password are all needed together — a username
   without a password is rejected when saving rather than failing silently at
   the relay.

### Slow pages
Queries taking longer than `SLOW_QUERY_MS` (default 500) are logged with the
table they hit. A long *queue* time in that log means the connection pool is
exhausted — raise `POOL_SIZE` — rather than the query itself being slow.
