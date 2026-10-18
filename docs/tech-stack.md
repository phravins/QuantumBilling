# Technology stack

QuantumBilling is a Phoenix LiveView application backed by PostgreSQL. The same Elixir release serves the user interface, handles downloads/provider callbacks and runs background workers. This inventory is taken from [`mix.exs`](../mix.exs), [`mix.lock`](../mix.lock), [`config/config.exs`](../config/config.exs), [`Dockerfile`](../Dockerfile) and [`docker-compose.yml`](../docker-compose.yml).

Versions below describe this checkout, not a recommendation to upgrade. `mix.exs` declares allowed dependency ranges; `mix.lock` records the actual resolved versions. Binary tooling and container runtime versions are configured separately.

## Runtime and data platform

| Technology | Declared or configured version | Use |
| --- | --- | --- |
| Application | `0.1.0` | Mix application/release name: `quantum_billing`. |
| Elixir | `~> 1.17` in Mix; `1.18.3` in Docker | Application language and Mix build/task tooling. |
| Erlang/OTP | Docker `27.3.4.8` | BEAM runtime, OTP supervisors/processes, ETS, crypto, TLS and networking. The Mix project does not independently pin OTP. |
| PostgreSQL | Compose `16-alpine` | Persistent relational data, schemas per business, indexes/constraints, transactions and Oban queue storage. |
| Debian | Docker `bookworm-20260610-slim` | Builder/runtime image base. |
| Chromium | Installed from the runtime image's package repository | Headless HTML-to-PDF rendering. No package version is pinned in the Dockerfile. |
| Docker / Docker Compose | Not version-pinned in this repository | Production-style local/container build and orchestration of database, migrations and app. |

There is no Redis, MongoDB, Kafka, Elasticsearch or object-storage service configured. Local image uploads live on disk. Monetary records use integer paise; Decimal handles quantity/boundary arithmetic.

## Web application dependencies

| Dependency | Requirement in Mix | Locked version | Role |
| --- | --- | --- | --- |
| `phoenix` | `~> 1.8.9` | `1.8.13` | Endpoint, routing, controllers, channels, application integration and verified routes. |
| `phoenix_live_view` | `~> 1.2.0` | `1.2.11` | Stateful server-rendered interactive screens, streams, events and colocated hooks/CSS. |
| `phoenix_html` | `~> 4.1` | `4.3.0` | HTML safety/helpers and browser form support. |
| `bandit` | `~> 1.5` | `1.12.5` | HTTP server via `Bandit.PhoenixAdapter`. |
| `phoenix_live_dashboard` | `~> 0.8.3` | `0.8.7` | Development metrics/request inspection dashboard. |
| `phoenix_live_reload` | `~> 1.2`, development only | `1.6.2` | Local browser reload and developer tooling. |
| `gettext` | `~> 1.0` | `1.0.2` | Translation/error-message infrastructure and `priv/gettext` catalogues. |
| `dns_cluster` | `~> 0.2.0` | `0.2.0` | Optional DNS-based Erlang node discovery. |

HEEx templates and Elixir function components are the primary rendering technology. Browser interactions use the Phoenix LiveView JavaScript client with WebSocket/long-poll support. A separate SPA framework is not required.

## Database and job dependencies

| Dependency | Requirement in Mix | Locked version | Role |
| --- | --- | --- | --- |
| `phoenix_ecto` | `~> 4.5` | `4.7.0` | Phoenix/Ecto integration. |
| `ecto_sql` | `~> 3.13` | `3.14.0` | SQL Repo adapter support, migrations and transactions. |
| `postgrex` | `>= 0.0.0` | `0.22.4` | PostgreSQL driver. |
| `oban` | `~> 2.18` | `2.24.1` | Persistent queues, retryable workers, uniqueness and Cron/maintenance plugins. |

The lockfile additionally resolves `ecto 3.14.1`, `decimal 3.1.1` and `db_connection 2.10.2`. Application code uses `Decimal` for exact quantity and money-boundary operations. Ecto changesets handle validation and schema mapping. `QuantumBilling.Repo` adds process-local PostgreSQL prefix routing for business tables.

Shared identities/business memberships/installation settings and Oban remain in `public`; each `biz_<id>` holds an independent set of business tables. Authenticated routes and public invoice/payment paths select a business, jobs carry it in their arguments, and PubSub topics include its schema. See [technical-architecture.md](technical-architecture.md#multi-business-model) and [database.md](database.md).

## HTTP, email and serialization dependencies

| Dependency | Requirement in Mix | Locked version | Role |
| --- | --- | --- | --- |
| `req` | `~> 0.5` | `0.7.4` | Application HTTP client for Razorpay, IRP, NIC and outgoing webhooks. |
| `swoosh` | `~> 1.16` | `1.26.3` | Email construction, delivery adapters, local preview and test mailbox assertions. |
| `gen_smtp` | `~> 1.2` | `1.3.0` | SMTP transport used by Swoosh's SMTP adapter. |
| `jason` | `~> 1.2` | `1.4.5` | JSON request/response, export and integration serialization. |
| `saxy` | `~> 1.6` | `1.6.1` | Parsing/serialization of invoice layout XML and e-invoice XML output. |

Req's resolved transport includes `finch 0.23.0` and `mint 1.10.0`. Application code should continue using the included Req client. XML layout processing uses Saxy rather than a browser-side template engine or `:xmerl`.

## Authentication and encryption dependencies

| Dependency or primitive | Requirement / locked version | Role |
| --- | --- | --- |
| `pbkdf2_elixir` | `~> 2.0` / `2.3.1` | Salted password hashes and recovery-code hashes. |
| `nimble_totp` | `~> 1.0` / `1.0.0` | Time-based one-time password generation/validation and authenticator URIs. |
| `eqrcode` | `~> 0.2` / `0.2.1` | Local QR generation for TOTP enrolment and payment QR output. |
| Erlang `:crypto` | Supplied by OTP | Random tokens, hashes, HMAC and AES-256-GCM encrypted field envelopes. |
| Plug / Plug.Crypto | Transitive `plug 1.20.3`, `plug_crypto 2.2.0` | Sessions, CSRF, secure comparison and web middleware. |
| ETS | Supplied by OTP | Node-local rate-limit counters. |

Authentication is implemented in the application's `Accounts` context and `UserAuth` module using Phoenix authentication conventions; no OAuth provider or external identity service is configured. Required encryption/session keys come from environment configuration or the local ignored `.env`. Integration secrets can also be stored through encrypted Ecto fields. The docs contain variable names and setup procedures, not live credentials.

## Frontend assets and styling

| Tool or asset | Configured / locked version | Use |
| --- | --- | --- |
| Tailwind CSS executable | `4.2.4` | CSS utility generation with v4 `@import`/`@source` syntax. |
| `tailwind` Mix wrapper | Requirement `~> 0.5`, lock `0.5.1` | Downloads/runs the standalone Tailwind executable. |
| esbuild executable | `0.25.4` | Bundles JavaScript with target `es2022`. |
| `esbuild` Mix wrapper | Requirement `~> 0.10`, lock `0.10.0` | Downloads/runs the standalone bundler. |
| Heroicons | Git tag `v2.2.0` | Local optimized SVG icon source used by the Tailwind plugin/shared icon component. |
| daisyUI | Git tag `v5.5.20` | Existing CSS plugin/theme dependency imported by `app.css`. New UI follows the project's custom Tailwind component guidelines. |
| Inter | Self-hosted WOFF2 files | Variable font subsets in `priv/static/fonts`, including the rupee glyph subset. |
| topbar | Vendored JavaScript; no separately locked version | Loading progress during LiveView navigation/form events. |
| Colocated LiveView hooks/CSS | Generated by LiveView's compiler | Hook and component CSS bundles imported through `phoenix-colocated/quantum_billing`. |

The frontend entry points are [`assets/js/app.js`](../assets/js/app.js) and [`assets/css/app.css`](../assets/css/app.css). The build uses Mix aliases, not an npm package script. There is no `package.json`-managed frontend application in the repository. `assets/tsconfig.json` provides editor/JavaScript project configuration; it does not introduce a TypeScript application compiler.

`mix assets.build` compiles Elixir then builds CSS/JS. `mix assets.deploy` compiles, minifies and generates the digest manifest. Compilation comes first because it creates the colocated asset modules imported by the bundles.

## Observability and testing

| Tool/dependency | Requirement / locked version | Use |
| --- | --- | --- |
| ExUnit | Supplied by Elixir | Test runner and assertions. |
| Ecto SQL Sandbox | Supplied by Ecto SQL | Isolated database tests and connection sharing for web tests. |
| Phoenix ConnTest / LiveViewTest | Supplied by Phoenix / LiveView | Controller, authentication and interactive UI tests. |
| `lazy_html` | `>= 0.1.0`, test only / `0.1.12` | HTML parsing and element selectors in component/LiveView assertions. |
| Swoosh test adapter | Supplied by Swoosh | Prevents real mail during tests and permits delivery assertions. |
| Oban inline testing | Supplied by Oban | Executes queued work in the configured test mode. |
| `telemetry_metrics` | `~> 1.0` / `1.1.0` | Phoenix, Repo and VM metric definitions. |
| `telemetry_poller` | `~> 1.0` / `1.3.0` | Periodic measurement scheduling. |
| Telemetry | Transitive lock `1.4.2` | Runtime event instrumentation and custom slow-query logging. |
| Logger | Supplied by Elixir/OTP | Request/job/slow-query operational logging. |

`mix precommit` is the repository's required final check. Its alias runs warning-free compilation, unused dependency unlocking, formatting and the test suite. The repository has context, worker, controller, LiveView, document, financial and security-oriented tests. No hosted CI pipeline is checked in; local aliases do not imply that an external CI service is configured.

## External systems and infrastructure boundaries

| System | Integration mechanism |
| --- | --- |
| SMTP relay | Swoosh/gen_smtp, configurable through environment or business settings. |
| Razorpay | Req payment-link requests and signed JSON webhook callbacks, with business selection from the callback URL slug. |
| IRP / NIC | Req HTTP clients with local sandbox behavior; source limitations are documented in the architecture/business guides. |
| Business webhook receiver | Queued Req JSON POSTs, optional HMAC signature and destination validation. |
| PostgreSQL server | Postgrex connection pool shared by web traffic and Oban. |
| TLS reverse proxy | Expected outside the application when using production HTTPS URLs; no proxy service is defined in Compose. |
| Upload volume | Local persistent filesystem; needs a shared/persistent solution when running multiple app instances. |

Simulation modes make local UI/workflow development possible without live provider accounts. They do not establish real government registration or collected payments. Read [configuration.md](configuration.md) before enabling providers, and [deployment.md](deployment.md) for runtime keys, volumes and release migration flow.

## Build and maintenance sources of truth

- Change dependency requirements in `mix.exs`, then deliberately update/commit `mix.lock` when upgrading.
- Change standalone CSS/JS executable versions in `config/config.exs`.
- Change the tested container language/runtime/base image in `Dockerfile` and the database image in `docker-compose.yml`.
- Keep the application version and the Compose uploads-volume release path in sync when bumping `0.1.0`.
- Keep this inventory aligned with source after dependency or architecture changes; setup and validation steps live in [getting-started.md](getting-started.md) and [development.md](development.md).
