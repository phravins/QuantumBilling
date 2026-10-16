# Development guide

Start with [getting started](getting-started.md), then read the [architecture](technical-architecture.md) and [database](database.md) guides before changing business-scoped behavior. Project conventions are in [`AGENTS.md`](../AGENTS.md).

## Repository map

| Location | Responsibility |
| --- | --- |
| `lib/quantum_billing/` | Domain contexts, schemas, integration clients, workers, encryption, Repo |
| `lib/quantum_billing_web/` | Router, endpoint, authentication, LiveViews, components, controllers, document renderers |
| `lib/mix/tasks/` | Business-schema migration task |
| `config/config.exs` | Common application/asset/Oban configuration and environment import |
| `config/dev.exs` / `test.exs` / `prod.exs` | Environment-specific framework settings |
| `config/runtime.exs` | `.env`, database credentials, keys, relay and deployment configuration |
| `assets/css/app.css` | Tailwind v4 entry, typography, component styling |
| `assets/js/app.js` | LiveSocket, generated hooks, topbar, development reload integration |
| `assets/vendor/` | Bundled asset helpers/plugins |
| `priv/repo/migrations/` | Public and historical migrations |
| `priv/repo/tenant_migrations/` | Migrations for every business schema |
| `priv/repo/seeds.exs` | First account (environment-configured login) and business 1's company settings |
| `priv/static/` | Static assets, fonts, images, and installation-specific uploads |
| `priv/gettext/` | Translation catalogs |
| `rel/overlays/bin/` | Release server/migration entrypoints |
| `test/quantum_billing/` | Context/domain/integration/worker tests |
| `test/quantum_billing_web/` | LiveView/controller/component/authorization tests |
| `test/support/` | SQL sandbox setup, connection helpers, account fixtures |
| `docs/` | Maintained Markdown documentation |

Generated build/dependency directories are `_build` and `deps`; generated web bundles are under `priv/static/assets`. They are not hand-edited source.

## Useful Mix commands

Read task options with `mix help <task>` before unfamiliar/destructive operations. Aliases are declared in [`mix.exs`](../mix.exs).

| Command | What it does |
| --- | --- |
| `mix deps.get` | Resolve/download locked dependencies |
| `mix compile` | Compile the application and generated LiveView assets |
| `mix ecto.create` | Create the selected environment's database |
| `mix ecto.migrate` | Public migrations, then registered business schemas |
| `mix quantum_billing.migrate_businesses` | Tenant migrations only; supports `--quiet` |
| `mix ecto.setup` | Create, migrate (public and business schemas), run seeds into business 1 |
| `mix setup` | Dependencies, `ecto.setup`, asset tools/build |
| `mix assets.setup` | Install standalone asset tools if missing |
| `mix assets.build` | Compile, build Tailwind, bundle JavaScript |
| `mix assets.deploy` | Compile, minify/bundle, digest static assets |
| `mix phx.server` | Start development server with configured watchers |
| `mix format` | Format project Elixir/HEEx inputs |
| `mix test` | Create/migrate test DB, then run ExUnit |
| `mix precommit` | Compile with warnings as errors, unlock unused deps, format, run tests |

`mix ecto.reset` drops the selected database and runs setup. It destroys data; use it only for an expendable local database. See [deployment](deployment.md) for migration/rollback boundaries.

## Tests and verification

Tests need `DB_USERNAME`, `DB_PASSWORD`, and the three required keys. `DB_NAME_TEST` selects the test database; `MIX_TEST_PARTITION` appends a partition suffix. Use a dedicated test database because test aliases run migrations automatically.

```bash
mix test test/quantum_billing/runtime_config_test.exs
mix test test/quantum_billing_web/live/invoices_live_test.exs
mix test --failed
mix precommit
```

Choose focused tests for the changed outcome, then complete `mix precommit`. It runs the formatter and dependency-unlock step as well as tests, so review the diff afterwards. This documentation change does not assert a fixed test count; the suite evolves.

`DataCase` owns SQL sandbox connections. `ConnCase` builds requests and supplies login helpers. LiveView tests use `Phoenix.LiveViewTest` and LazyHTML with stable DOM IDs. Worker tests use Oban's inline testing configuration; email uses Swoosh's test adapter. Domain coverage includes paise arithmetic, invoices, public tokens, authentication, uploads, signature checks, SSRF guards, encrypted values, reports, and document generation.

`DataCase` and `ConnCase` select business 1 for each test, and user fixtures create a membership in it. Tests that create further businesses (`Businesses.create/2`) run DDL, so they use `async: false`, and they switch with `Repo.with_business/2`. A test that raises `NoBusinessError` usually started a process that did not select a business; give it the same explicit selection production code needs. Do not add an implicit shared-schema fallback just to make a test pass.

For process tests use supervised test processes, monitors, and synchronization instead of sleeps. Add regression tests for meaningful behavior changes rather than assertions that repeat implementation details.

## Making changes

### Business data and migrations

Shared account/business registry models declare the `public` prefix. Business tables have no fixed schema prefix and require `Repo.put_business/1` or `Repo.with_business/2` in their process. Process-local state is not inherited: a `Task` must be handed the business and select it, and an Oban worker must `use QuantumBilling.Worker` (not `use Oban.Worker`) and implement `process/1`, so the job records the queuing business as `"business_id"` and runs in it. A cron worker that should visit every business passes `sweep: true`. Inside a migration, data queries follow the migration's own prefix rather than the current business.

Generate migration filenames through `mix ecto.gen.migration descriptive_name`. Decide whether a migration belongs to public metadata or to every business schema. Business table changes belong in `priv/repo/tenant_migrations` (`mix ecto.gen.migration descriptive_name --migrations-path priv/repo/tenant_migrations`); `mix ecto.migrate` then applies them to every business. Do not edit the tenant baseline migration to change existing businesses; they have already run it. Raw SQL must qualify business schemas because Ecto query prefixing does not rewrite SQL strings.

### Phoenix and UI

Keep authentication and owner restrictions at the router and LiveView hook boundaries. The existing router has several sessions; inspect the actual blocks and group routes appropriately rather than duplicating session names. Use `current_scope`, including its selected membership/business, for authorization. [Architecture](technical-architecture.md) maps the current sessions and remaining business selection work.

Use HEEx, shared layouts/components, `<.input>`, `<.icon>`, stable IDs, `to_form`, and LiveView streams for collections. Use modern `<.link navigate>` / `<.link patch>` and socket navigation APIs. Keep custom JavaScript in `app.js` or supported colocated hooks; imports must be bundled. Tailwind v4's source/import syntax remains in `app.css`; do not introduce `@apply` or new daisyUI-based components.

### Integrations and money

Use the included `Req` client for HTTP. Keep network calls out of long-running UI handlers where workers already provide retries/history. Verify sandbox and live response behavior independently.

Money fields use integer paise/custom `Money.Paise` types. Decimal quantities/percentages remain separate. Follow the existing conversion/rounding APIs and verify final invoice/report outcomes; do not introduce floating-point money storage.

### Configuration and documentation

Add new environment variable names to `.env.example` with empty secrets, update Compose mappings when needed, and explain them in [configuration](configuration.md). Keep actual credentials out of logs, fixtures copied from production, docs, and tracked files.

Update the business guide for workflow changes, database guide for storage changes, and architecture guide for ownership/process changes. Check relative links and examples against the files and task aliases present in the checkout.
