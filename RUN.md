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

- **Run the full test suite (754 tests)**:
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
