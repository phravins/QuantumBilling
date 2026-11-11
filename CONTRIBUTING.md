# Contributing to QuantumBilling

Thanks for helping. QuantumBilling keeps businesses' invoices, tax records and
customer data, so a change here has to be correct as well as working. This
guide covers how to propose a change, what must pass before review, and the
rules that protect that data. The detail lives in [`docs/`](docs/README.md);
this page links to it rather than repeating it.

By contributing, you agree that your contribution is licensed under the
project's [MIT licence](LICENSE).

**Found a security problem?** Don't open a public issue. See
[Reporting a vulnerability](#reporting-a-vulnerability).

## Before you start

- **For anything beyond a small fix, open an issue first.** Describe the
  problem and the change you have in mind. A new feature, a schema change, a
  new dependency or anything that touches money, tax or permissions is much
  easier to agree on before it's written.
- **Read the guides for the area you're changing:**
  - [Getting started](docs/getting-started.md): local setup.
  - [Development](docs/development.md): repository map, Mix commands, testing.
  - [Technical architecture](docs/technical-architecture.md) and
    [Database](docs/database.md): read these before changing anything a
    business owns.
  - [Business guide](docs/Business.md): how GST, VAT and the billing
    workflows behave.
  - [`AGENTS.md`](AGENTS.md): the Phoenix, LiveView, Ecto and HEEx conventions
    the code follows.

## Setting up

Follow [Getting started](docs/getting-started.md). In short: you need
Elixir 1.18 on OTP 27 and PostgreSQL 16.

```bash
cp .env.example .env   # fill in DB credentials and the three keys (mix phx.gen.secret)
mix setup              # deps, database, migrations, seeds, assets
mix phx.server
```

`mix test` creates and migrates its own test database, so point
`DB_NAME_TEST` at one you don't mind losing.

## Making a change

1. **Branch from an up-to-date `main`**, one branch per change.
2. **Keep the change focused.** A fix and an unrelated refactor are two pull
   requests. Don't reformat or rename code you aren't otherwise changing.
3. **Write a test for the behaviour you changed** (see [Tests](#tests)).
4. **Update the docs the change affects** (see [Documentation](#documentation)).
5. **Run the checks** below and fix everything they report.
6. **Open a pull request** against `main` (see [Pull requests](#pull-requests)).

### Commit messages

Start the subject with what kind of change it is, then say what it does, in
the imperative:

```
Fix: Clients Export downloading a tax summary
Add: client import from CSV/Excel
Clean: remove unused functions and dead tests
```

Use the body for the *why*: what was wrong, what the change does about it, and
anything a reviewer should look at closely. A security or data-correctness fix
should say what could happen before it.

## Checks

There's no CI yet, so reviewers rely on you having run these. Say in the pull
request that you did.

```bash
mix precommit
```

This compiles with warnings as errors, drops unused locked dependencies,
formats the code and runs the whole test suite. It must finish clean. It can
change files (formatting, `mix.lock`), so review and commit what it changes.

For changes to request handling, authentication, uploads, redirects or raw
SQL, also run [Sobelow](https://github.com/nccgroup/sobelow), the Phoenix
security scanner:

```bash
mix archive.install hex sobelow   # once
mix sobelow --config              # reads .sobelow-conf
```

A new finding is fixed, not skipped. If one is genuinely a false positive, it
goes in `.sobelow-conf` with the reason beside it, and the pull request says
why.

Some tests guard the project rather than one feature. When one fails, fix the
cause rather than the test:

| Test | Fails when |
| --- | --- |
| `DependencyFloorTest` | A dependency drops below the first release without a known vulnerability |
| `OpenAPITest` (`api_openapi_test.exs`) | `docs/openapi.json` no longer matches the API's routes, serializers or scopes |
| `ScopesTest` (`api_scopes_test.exs`) | An API route is added without its scope being checked |
| `TenantIsolationTest`, `API.TenancyTest` | One business can reach another's records |
| `WebhooksOutgoingTest` | A webhook event type has nothing publishing it |
| `DocsVersionTest` | The README or docs index stops naming the release version in `mix.exs` |

## Rules that protect the data

These aren't style preferences. Each one exists because breaking it leaks
data, corrupts records or lets someone do what their role doesn't allow. A
pull request that breaks one won't be merged.

### Every business's data stays in its own schema

Each business has its own PostgreSQL schema (`biz_1`, `biz_2`, …), chosen per
process with `Repo.put_business/1` or `Repo.with_business/2`.

- Never add a fallback that reads a business table without a business chosen.
  If you see `NoBusinessError`, the fix is to choose the business.
- Background jobs `use QuantumBilling.Worker` (not `Oban.Worker`) and implement
  `process/1`, so they run in the business that queued them. A `Task` must be
  handed the business and select it.
- Business-table changes go in `priv/repo/tenant_migrations`; the public
  migrations hold only shared tables. Never edit a migration that has already
  run. Raw SQL must name the schema itself.
- PubSub topics for business data go through `QuantumBilling.Events`, which
  includes the business. Record ids repeat across businesses, so an unscoped
  `"invoice:5"` topic would mix them.

### Check roles on the server, everywhere

- Owner-only pages sit in the router's owner `live_session` and pipeline, not
  just behind a hidden link.
- **Any connected client can send any event to a LiveView, whatever page it
  shows.** An owner-only `handle_event` must check
  `Scope.owner?(socket.assigns.current_scope)` itself.
- Authorize from `current_scope`, never from something the client sent.

### Never take server-decided fields from input

Fields the application decides (an invoice's status, number, company
snapshot, layout, IRN and payment details) are never cast from form or API
params.

- Pass them to `Invoice.changeset/3` as `trusted` instead.
- A new field that only the server sets belongs in that `@trusted` list, not
  `@castable`.
- Elsewhere, fields set in code (`user_id`, `business_id`, …) are put on the
  struct, never cast. A crafted form post must not be able to mark an invoice
  Paid.

### Money is integer paise

Store and compute money as integer paise through the `Money` and
`Money.Paise` APIs. No floats, ever, and verify totals end to end. The API
sends and receives paise too.

### The external API

- Responses are built from **explicit field lists** in the `*JSON` modules.
  Never serialise a struct wholesale; a new column must not appear in the API
  by accident.
- Request bodies go through an **input allowlist** that refuses unknown
  fields by name (`InvoiceParams`, `ClientParams`, `ActionParams`).
- A new route needs its own scope, a row in the scope test, an entry in
  `docs/openapi.json`, and the `Idempotency-Key` rule if it writes.
- Controllers call context functions, never `Repo`, so the Bin and business
  scoping apply.

### Outbound requests and webhooks

- Use `Req`. A URL that a user typed goes through `UrlGuard.pin/1` and is
  requested with redirects off. That blocks requests into the server's own
  network, including by DNS rebinding.
- Webhook events stay thin (`{id, type, created_at, data: {object, id}}`). A
  new event type needs a publisher and a row in `docs/webhooks.md`.

### Secrets and personal data

- No credentials, tokens, keys or customer data in code, fixtures, logs, docs
  or commit history. Copy nothing from a production database.
- Credentials stored in the database use the encrypted Ecto types. Tokens and
  keys that are only ever compared are stored as hashes.
- A new environment variable goes in `.env.example` with an empty value, and
  in [Configuration](docs/configuration.md).
- New request parameters that carry secrets must match `filter_parameters` in
  `config/config.exs`, so they don't reach the logs.

### Dependencies

- Add a dependency only when the standard library and the existing ones
  (`Req` for HTTP, `Jason`, `Saxy`, …) can't reasonably do the job, and say
  why in the pull request.
- Commit `mix.lock` with any dependency change. Never lower a floor in
  `DependencyFloorTest`; when a new advisory lands, raise it.

## Tests

- **Every behaviour change gets a test, and every bug fix gets a regression
  test.** For a security or data fix, check that the test fails without the
  fix.
- Test outcomes, not implementation: what the user sees, what's stored, what
  an attacker is refused.
- LiveView tests drive the page through `Phoenix.LiveViewTest` and assert on
  stable DOM IDs, not raw HTML.
- Tests that create a business run DDL, so they use `async: false`.
- No `Process.sleep/1`. Use monitors, `:sys.get_state/1` and
  `start_supervised!/1`.
- Tests never depend on the network or on real DNS. HTTP goes through
  `Req.Test`, and outbound URL checks resolve through
  `QuantumBilling.FakeDNS`.

[Development › Tests and verification](docs/development.md#tests-and-verification)
covers the test cases, fixtures and helpers.

## Documentation

Docs are part of the change. Update:

| If you changed… | Update |
| --- | --- |
| A workflow, setting or business rule | [Business guide](docs/Business.md) |
| A table, column, index or migration | [Database](docs/database.md) |
| Process, ownership, jobs or security controls | [Technical architecture](docs/technical-architecture.md) |
| An environment variable | [Configuration](docs/configuration.md) and `.env.example` |
| The API | [API](docs/api.md) and [`openapi.json`](docs/openapi.json) |
| Webhook events or delivery | [Webhooks](docs/webhooks.md) |
| Release or deploy steps | [Deployment](docs/deployment.md) |
| Screens | The screenshots in `docs/assets/screenshots` |

Check that every link and command you write matches the files and Mix
aliases in your checkout.

## Pull requests

In the description, cover:

- **What and why:** the problem and how the change solves it. Link the issue.
- **How you tested it:** the tests you added, and confirmation that
  `mix precommit` (and Sobelow, if relevant) ran clean.
- **Screenshots** for visible UI changes.
- **Migrations:** whether they're public or tenant, whether they change
  existing data, and how to roll back.
- **Configuration:** new or changed environment variables.
- **Security and data impact:** who can now do or see something they
  couldn't before, or the other way round. "None" is a fine answer when true.

Reviewers will ask for changes when something is unclear, untested or breaks
one of the rules above. Push follow-up commits to the same branch; don't open
a new pull request.

## Reporting a vulnerability

Please don't open a public issue, discussion or pull request for a security
problem.

Report it privately through GitHub: on the repository's **Security** tab,
choose **Report a vulnerability**. If that option isn't there, contact the
maintainer, [@phravins](https://github.com/phravins), privately on GitHub
first, and only share the details once you have a private channel.

Include what's affected, how to reproduce it, and the impact you expect.
Please give a reasonable time for a fix before disclosing it publicly. Test
only against your own installation, never against someone else's data.
