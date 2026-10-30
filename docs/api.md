# QuantumBilling API (v1)

A JSON API for your own systems — an accounting package, a website checkout, an
internal dashboard — to read invoices, clients and e-way bills, and to create
invoices and clients.

It is server-to-server only. Keys belong in the other system's server
configuration, never in a web page, a mobile app or a URL.

## Keys

An **owner** creates keys under **Settings › API keys**, in the business they
are working in. **A key belongs to that one business**: it reads and writes that
business's books only, and nothing in a request can point it at another. On an
installation that keeps several businesses, each needs keys of its own. If a
business is archived, its keys stop working.

Each key has:

- a **name** — use the name of the system that will hold it;
- **permissions** (scopes) — tick only what that system needs;
- an **expiry** — 30 days, 90 days, 1 year, or never.

The key is shown **once**, when it is created. Only a SHA-256 fingerprint of it
is stored, so it cannot be shown again: if it is lost, revoke it and create
another. Revoking takes effect on the next request.

Every write made with a key is in the audit log under that key, with the
caller's IP address. The keys page shows when each key was last used, and from
where.

### Scopes

| Scope | Allows |
|---|---|
| `invoices:read` | `GET /invoices`, `GET /invoices/:id` |
| `invoices:write` | `POST /invoices` |
| `invoices:payment_links` | adds `payment_url` (the customer's payment page) to invoices. That URL lets anyone who has it view the invoice and pay it, so grant this only to a system that is meant to send it to the customer |
| `clients:read` | `GET /clients`, `GET /clients/:id` — including contact details |
| `clients:write` | `POST /clients` |
| `e_way_bills:read` | `GET /e-way-bills`, `GET /e-way-bills/:id` |

`GET /me` works with any key.

## Making a request

```
GET https://billing.example.com/api/v1/invoices
Authorization: Bearer qb_live_…
Accept: application/json
```

- **https only.** A request over plain http is refused with `403
  https_required` rather than redirected — by the time it arrives, the key has
  already crossed the network unencrypted. Treat a key sent that way as exposed:
  revoke it.
- **The key goes in the `Authorization` header only.** A key in the query string
  (`?api_key=…`, `?token=…`, …) is refused with `400 key_in_url`, even if a valid
  header is also present. URLs end up in logs and browser history.
- **No cookies, no sessions, no CORS.** A browser cannot call this API from a
  web page, by design.

## Errors

Every error has the same shape:

```json
{"error": {"code": "validation_failed", "message": "The invoice is invalid.",
           "fields": {"place_of_supply": ["is invalid"]}}}
```

`code` is stable; branch on it. `message` is for people. `fields` appears on
validation errors. Error responses never repeat the values you sent.

| Status | `code` | Meaning |
|---|---|---|
| 400 | `key_in_url` | A key was sent in the URL |
| 400 | `idempotency_key_required` | A write had no (or a malformed) `Idempotency-Key` |
| 400 | `invalid_parameters` | `page` / `per_page` out of range |
| 401 | `unauthorized` | No key, or a key that is wrong, revoked or expired — deliberately indistinguishable |
| 403 | `insufficient_scope` | The key lacks the scope this route needs |
| 403 | `https_required` | The request was made over http |
| 404 | `not_found` | No such record — or one that is in the Bin; the two look identical |
| 409 | `idempotency_in_progress` | The first request with this key has not finished |
| 422 | `validation_failed` | The body was rejected; see `fields` |
| 422 | `idempotency_mismatch` | The key was already used for a different request |
| 429 | `rate_limited` | Too many requests; wait `retry-after` seconds |

## Rate limits

Per key, per minute: **600 reads** and **60 writes**. Every response carries
`x-ratelimit-limit` and `x-ratelimit-remaining`; a 429 carries `retry-after`.

## Pagination

List endpoints take `page` (1 to 1000) and `per_page` (default 25, at most 100),
and return:

```json
{"data": [ … ], "meta": {"page": 1, "per_page": 25, "has_next": true}}
```

Keep requesting the next page while `has_next` is true. Lists are not counted —
counting a large table on every page is what made the screens slow — so there
is no total. A page past the end returns `"data": []`. Pages stop at 1000; to
reach further, narrow the list with `status` or `search`.

Lists also accept `status` (exact match, e.g. `Draft`, `Paid`) and `search`.

## Writes and idempotency

Every `POST` must carry an `Idempotency-Key` header: a value you generate, unique
per intended write, up to 255 characters — a UUID is ideal.

If a response is lost, send the **identical** request with the **same** key. You
get the original response back (with `idempotent-replayed: true`) and nothing is
created twice. This matters for invoices: each one consumes the next number in a
statutory series, and a duplicate cannot simply be deleted.

- Same key, different body → `422 idempotency_mismatch`.
- Same key while the first is still running → `409`; retry shortly.
- Keys are remembered for 24 hours, per API key.
- A server error (5xx) is not remembered, so it can be retried with the same key.

### Unknown fields are refused, not ignored

A write body may contain only the fields documented below. Anything else is
rejected by name (`"is not accepted by the API"`) so that a typo — or an
attempt to set something the application controls — fails loudly instead of
seeming to work.

## Endpoints

### `GET /api/v1/me`

The calling key's `name`, `prefix`, `scopes`, `expires_at` and `created_at`.

### `GET /api/v1/invoices` · `GET /api/v1/invoices/:id`

```json
{
  "id": 42, "number": "INV-0042", "type": "Tax Invoice", "status": "Draft",
  "invoice_date": "2026-10-01", "due_date": "2026-10-31", "payment_terms": "Net 30 Days",
  "place_of_supply": "Maharashtra (27)", "currency": "INR",
  "client": {"id": 7, "name": "Northwind Traders", "gstin": "27…", "state": "Maharashtra (27)"},
  "amounts": {"taxable_value": 10000, "cgst": 900, "sgst": 900, "igst": 0, "cess": 0,
              "round_off": 0, "grand_total": 11800},
  "e_invoice": {"irn": null, "ack_number": null, "ack_date": null},
  "remarks": null, "terms": null, "created_at": "…", "updated_at": "…"
}
```

**Every amount is an integer number of paise** (₹1 = 100 paise), in responses
and in requests alike — `11800` above is ₹118.00. Integers, so nothing is lost to
floating-point rounding on a tax figure.

`GET /invoices/:id` adds `items` (`position`, `description`, `hsn_sac`,
`quantity`, `unit`, `rate`, `tax_rate`, `amount`). `quantity` is a decimal sent
as a string (`"2.5"`); `rate` and `amount` are paise. `payment_url` is added only
for keys with `invoices:payment_links`, and names the business
(`https://…/p/<business>/<token>`).

The client's email, PAN and address are not on invoices; read them from
`/clients` with `clients:read`.

### `POST /api/v1/invoices`

```json
{
  "client_id": 7,
  "invoice_type": "Tax Invoice",
  "invoice_date": "2026-10-01",
  "due_date": "2026-10-31",
  "payment_terms": "Net 30 Days",
  "place_of_supply": "Maharashtra (27)",
  "remarks": "PO 1182",
  "terms": "Payable within 30 days.",
  "items": [
    {"description": "Consulting", "hsn_sac": "998313", "quantity": 2, "unit": "Nos",
     "rate": 500000, "tax_rate": 18}
  ]
}
```

Required: `client_id`, `invoice_date`, `place_of_supply`, and 1–200 `items`, each
with a `description`. `rate` is paise (`500000` is ₹5,000.00) and must be a whole
number; `quantity` may be a number or a decimal string. The invoice is created as
a **Draft**.

The server decides, and the body cannot set: the invoice number; your company's
details; the client's name, GSTIN and address (copied from the client record);
the status; anything to do with e-invoicing or payment. Returns `201` with the
invoice as `GET /invoices/:id` shows it.

### `GET /api/v1/clients` · `GET /api/v1/clients/:id`

`id`, `type`, `name`, `display_name`, `legal_name`, `gstin`, `pan`,
`business_type`, `category`, `email`, `phone`, `billing_address`,
`shipping_address` (each `{line1, line2, city, state, pin}`),
`payment_terms_days`, `status`, `created_at`, `updated_at`.

Internal notes, credit limits and balances are not exposed.

### `POST /api/v1/clients`

The same shape as a client read, without `id`, `status` or the timestamps.
`type`, `name`, `phone` and `billing_address` are required. Omit
`shipping_address` when it is the same as billing. `phone_country_code` is also
accepted (default `+91`). The client is created **Active** with no credit limit
and no opening balance — those are set in the application.

### `GET /api/v1/e-way-bills` · `GET /api/v1/e-way-bills/:id`

`id`, `number`, `date`, `valid_until`, `status`, `distance_km`,
`mode_of_transport`, `vehicle_number`, `transporter_id`, `transporter_name`,
`cancelled_at`, `cancellation_reason`, `invoice` (`{id, number}`),
`created_at`, `updated_at`. Read-only.

## The Bin

Records in the Bin — and e-way bills whose invoice is in the Bin — are absent
from lists and return `404` by id, exactly as if they did not exist. Restoring
one from the Bin makes it visible again.

## Webhooks

Outgoing webhooks are being reworked to send thin, signed events (`{id, type,
created_at, data: {object, id}}`) that you then fetch through this API. This
section will describe them when they ship.
