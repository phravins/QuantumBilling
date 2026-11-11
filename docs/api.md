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
| `invoices:write` | `POST /invoices`, `POST /invoices/:id/cancel` |
| `invoices:payment_links` | adds `payment_url` (the customer's payment page) to invoices. That URL lets anyone who has it view the invoice and pay it, so grant this only to a system that is meant to send it to the customer |
| `invoices:payments` | `POST /invoices/:id/payments` — mark an invoice paid. Separate from `invoices:write`: creating invoices and declaring them paid are different trust |
| `invoices:e_invoice` | `POST /invoices/:id/e-invoice` — register with the government IRP (India GST only) |
| `credit_notes:read` | `GET /credit-notes`, `GET /credit-notes/:id` |
| `credit_notes:write` | `POST /invoices/:id/credit-notes` |
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
| 400 | `invalid_parameters` (`cursor`) | A cursor this API did not issue |
| 409 | `idempotency_in_progress` | The first request with this key has not finished |
| 409 | `already_paid`, `cancelled`, `already_cancelled`, `paid`, `irn_registered`, `live_e_way_bill` | The action conflicts with the invoice's state; see the action below |
| 409 | `gst_only` | An India GST feature (IRP e-invoice) asked of a VAT business or a VAT invoice |
| 422 | `validation_failed` | The body was rejected; see `fields` |
| 422 | `idempotency_mismatch` | The key was already used for a different request |
| 429 | `rate_limited` | Too many requests; wait `retry-after` seconds |

## Rate limits

Per key, per minute: **600 reads** and **60 writes**, counted across every
server the installation runs on. Every response carries `x-ratelimit-limit` and
`x-ratelimit-remaining`; a 429 carries `retry-after`.

## Pagination

List endpoints take `page` (1 to 1000) and `per_page` (default 25, at most 100),
and return:

```json
{"data": [ … ], "meta": {"page": 1, "per_page": 25, "has_next": true}}
```

Keep requesting the next page while `has_next` is true. Lists are not counted —
counting a large table on every page is what made the screens slow — so there
is no total. A page past the end returns `"data": []`. Pages stop at 1000.

### Cursor paging — for syncing

Add `paginate=cursor` to the first request. Records come newest-created first,
and `meta` carries a cursor instead of a page number:

```json
{"data": [ … ], "meta": {"per_page": 100, "has_next": true, "next_cursor": "djE6MTIzNDU"}}
```

Pass it back as `cursor=…` for the next page, until `has_next` is false and
`next_cursor` is null. There is no depth limit, every request costs the same
however far in you are, and records created while you page don't shift the
pages after them. Treat the cursor as opaque. Credit notes are cursor-paged
only.

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

## Tax regimes

A business charges either **India GST** or **VAT** (Settings › Tax). Every
invoice carries the regime it was raised under in `tax_regime`, and keeps it if
the business later switches. Write bodies follow the business's current regime:

| | GST business | VAT business |
|---|---|---|
| Line tax | `tax_rate`: a GST slab (0, 5, 12, 18, 28) | `tax_rate_id`: an active VAT rate's id; left out, the business's default rate |
| Invoice | `place_of_supply` required | `place_of_supply` optional; `reverse_charge` (boolean) accepted |
| Refused | `tax_rate_id`, `reverse_charge` — "is for VAT invoices; this business charges GST" | `tax_rate` — "is for GST invoices; a VAT line takes tax_rate_id" |

The rates and their ids are managed by owners in the application; the API
reads the rate a line used but does not list or change rates. IRP e-invoicing
is GST-only and is refused with `409 gst_only` under VAT.

## Custom fields

Owners add their own fields at Settings › Data model. Clients, invoices and
invoice lines carry them in a `custom_fields` object, keyed by each field's
`key` (fixed when the field is created). Only fields marked **Included in the
API** appear in responses or are accepted in writes; any other key is refused
by name (`"is not accepted by the API"`). Keys you leave out are left empty
(defaults only prefill the application's forms), except that a required field
must be given when the record is created. A field that has no value is absent
from the object; sending `null`, `""` or `[]` is the same as leaving it out.

| Type | Value |
|---|---|
| `text`, `long_text`, `email`, `phone`, `url` | String (up to 500 characters; 5,000 for `long_text`) |
| `number` | Decimal string, e.g. `"12.5"` |
| `money` | Integer minor units, like every amount (`125050` is 1,250.50) |
| `date` | `"YYYY-MM-DD"` |
| `boolean` | `true` / `false` |
| `select` | The choice's id |
| `multi_select` | A list of choice ids |

A choice's id stays the same when the owner renames it. When writing, a choice
may also be given by its label, in any case; responses always give the id. Values are checked
as they are in the application, and a bad one fails with `422`. A refused key,
or a `money` value that is not a whole number, is named by its path, e.g.
`"custom_fields.po_number"` or `"items.0.custom_fields.batch"`. A value that
fails the field's own check (a malformed email, a choice id that doesn't exist,
a missing required field) is reported under `custom_fields`, or under that line
in `items`, with the field's label in the message.
Webhook payloads do not carry custom fields; fetch the record. Credit notes
and e-way bills don't expose their custom fields through the API.

## Endpoints

### `GET /api/v1/me`

The calling key's `name`, `prefix`, `scopes`, `expires_at` and `created_at`.

### `GET /api/v1/invoices` · `GET /api/v1/invoices/:id`

```json
{
  "id": 42, "number": "INV-0042", "type": "Tax Invoice", "status": "Draft",
  "invoice_date": "2026-10-01", "due_date": "2026-10-31", "payment_terms": "Net 30 Days",
  "place_of_supply": "Maharashtra (27)", "currency": "INR",
  "tax_regime": "gst", "reverse_charge": false, "tax_breakdown": [],
  "client": {"id": 7, "name": "Northwind Traders", "gstin": "27…", "tax_number": null,
             "state": "Maharashtra (27)"},
  "amounts": {"taxable_value": 10000, "cgst": 900, "sgst": 900, "igst": 0, "cess": 0,
              "vat": 0, "round_off": 0, "grand_total": 11800},
  "e_invoice": {"irn": null, "ack_number": null, "ack_date": null, "mode": null},
  "remarks": null, "terms": null, "custom_fields": {"po_number": "PO 1182"},
  "created_at": "…", "updated_at": "…"
}
```

**Every amount is an integer number of minor units of the invoice's
`currency`** — paise for INR (₹1 = 100 paise), fils for AED, pence for GBP — in
responses and in requests alike. `11800` above is ₹118.00. Integers, so nothing
is lost to floating-point rounding on a tax figure. The API never converts
between currencies.

A VAT invoice has no CGST/SGST/IGST split. Its VAT is in `amounts.vat`, with
one `tax_breakdown` row per rate (`rate_bp` is basis points: 500 = 5%), and the
client's VAT number in `client.tax_number`:

```json
{
  "currency": "AED", "tax_regime": "vat", "reverse_charge": false, "place_of_supply": null,
  "tax_breakdown": [
    {"name": "Standard 5%", "category": "standard", "rate_bp": 500, "taxable": 24998, "tax": 1250},
    {"name": "Zero-rated", "category": "zero", "rate_bp": 0, "taxable": 10000, "tax": 0}
  ],
  "amounts": {"taxable_value": 34998, "cgst": 0, "sgst": 0, "igst": 0, "cess": 0,
              "vat": 1250, "round_off": 0, "grand_total": 36248}
}
```

`GET /invoices/:id` adds `items` (`position`, `description`, `hsn_sac`,
`quantity`, `unit`, `rate`, `tax_rate`, `tax_rate_id`, `tax_rate_bp`,
`tax_category`, `tax_name`, `amount`, `custom_fields`). `quantity` is a decimal
sent as a string (`"2.5"`); `rate` and `amount` are minor units. A GST line has
its slab in `tax_rate`. A VAT line has `tax_rate` 0 and keeps the rate's name,
category and basis points as they were when it was saved, so editing the rate
later doesn't change it. `payment_url` is added only
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
  "custom_fields": {"po_number": "PO 1182"},
  "items": [
    {"description": "Consulting", "hsn_sac": "998313", "quantity": 2, "unit": "Nos",
     "rate": 500000, "tax_rate": 18}
  ]
}
```

For a VAT business, leave out `place_of_supply` and `tax_rate`, and give each
line a `tax_rate_id` (or none, for the default rate):

```json
{"client_id": 7, "invoice_date": "2026-10-01", "reverse_charge": false,
 "items": [{"description": "Consulting", "quantity": 2, "rate": 50000, "tax_rate_id": 3}]}
```

Required: `client_id`, `invoice_date`, 1–200 `items` each with a
`description`, and, for a GST business, `place_of_supply`. `rate` is minor
units of the business currency (`500000` is ₹5,000.00) and must be a whole
number; `quantity` may be a number or a decimal string. A VAT rate that is
archived or unknown is refused as `{"items": [{"tax_rate_id": ["…"]}]}`. See
[Tax regimes](#tax-regimes) and [Custom fields](#custom-fields). The invoice
is created as a **Draft**, in the business currency.

The server decides, and the body cannot set: the invoice number; your company's
details; the client's name, GSTIN or VAT number, and address (copied from the
client record); the currency and tax regime; the status; anything to do with
e-invoicing or payment. Returns `201` with the invoice as `GET /invoices/:id`
shows it.

### `GET /api/v1/clients` · `GET /api/v1/clients/:id`

`id`, `type`, `name`, `display_name`, `legal_name`, `gstin`, `pan`,
`tax_number`, `country`, `business_type`, `category`, `email`, `phone`,
`billing_address`, `shipping_address` (each `{line1, line2, city, state, pin}`),
`payment_terms_days`, `status`, `custom_fields`, `created_at`, `updated_at`.

`tax_number` is the client's VAT number and `country` its ISO-2 country code
(`IN` by default), used by VAT businesses in place of `gstin` and `pan`.
Internal notes, credit limits and balances are not exposed.

### `POST /api/v1/clients`

The same shape as a client read, without `id`, `status` or the timestamps.
`type`, `name`, `phone` and `billing_address` are required. Omit
`shipping_address` when it is the same as billing. `phone_country_code` is also
accepted (default `+91`). For a VAT business, `tax_number` is checked against
the format for `country`, and the GSTIN and PAN checks are skipped. The client
is created **Active** with no credit limit and no opening balance — those are
set in the application.

### `GET /api/v1/e-way-bills` · `GET /api/v1/e-way-bills/:id`

`id`, `number`, `date`, `valid_until`, `status`, `distance_km`,
`mode_of_transport`, `vehicle_number`, `transporter_id`, `transporter_name`,
`cancelled_at`, `cancellation_reason`, `invoice` (`{id, number}`),
`created_at`, `updated_at`. Read-only. `status` is `Active`, `Expired` (past
`valid_until`) or `Cancelled`. E-way bills are an India GST feature; a business
that switches to VAT can still read the bills it issued before.

### `POST /api/v1/invoices/:id/payments`

Records a payment received outside the payment gateway — a bank transfer your
accounting system has matched, for example. Needs `invoices:payments`.

```json
{"reference": "NEFT-HDFC-0042", "amount": 1180000}
```

`amount` is paise and must cover the invoice's `grand_total`; partial payments
are refused (422) rather than recorded as paid in full. The invoice becomes
**Paid**, the customer gets a receipt, and `invoice.paid` is sent to webhooks,
exactly as for a gateway payment. 409 `already_paid` or `cancelled` if it can't
be paid. Returns the invoice.

### `POST /api/v1/invoices/:id/cancel`

```json
{"reason": "Duplicate order"}
```

The invoice keeps its number and leaves GSTR-1. Refused with 409 when
cancelling here would not be the whole story:

- `paid` — raise a credit note instead;
- `irn_registered` — a live IRN must be cancelled on the IRP first;
- `live_e_way_bill` — cancel the e-way bill first;
- `already_cancelled`.

Sends `invoice.cancelled`. Returns the invoice.

### `POST /api/v1/invoices/:id/e-invoice`

Queues registration with the IRP; the body is `{}`. Answers **202**
`{"data": {"status": "queued", …}}`, or 200 `already_registered`. Refused with
409 `cancelled` for a cancelled invoice and `paid` for a paid one: registering
would overwrite that status, and 409 `gst_only` when the business charges VAT
or the invoice was raised under VAT. The outcome
arrives as `invoice.e_invoice_generated` / `invoice.e_invoice_failed`, or by
fetching the invoice: `e_invoice.irn` is set, and `e_invoice.mode` says `live`
or `demo` (made by the sandbox, never filed with the government). Needs
`invoices:e_invoice`.

### `POST /api/v1/invoices/:id/credit-notes` · `GET /api/v1/credit-notes` · `GET /api/v1/credit-notes/:id`

```json
{"type": "credit", "reason": "Damaged goods", "subtotal": 100000, "tax_total": 18000, "grand_total": 118000}
```

`type` is `credit` or `debit`; amounts are minor units of the invoice's
currency, and any left out default to the invoice's own. A note follows its
invoice's tax regime; on a VAT invoice `tax_total` is VAT, spread across the
invoice's rates in proportion. A note reads back as `id`, `number`, `type`, `reason`,
`status`, `amounts` (`subtotal`, `tax_total`, `grand_total`), `invoice`
(`{id, number}`), `client_id`, `created_at`, `updated_at`. Notes on an invoice
in the Bin are hidden.

## OpenAPI

[`openapi.json`](openapi.json) describes every endpoint, scope and response
shape, for generating a client. A test keeps it identical to the routes and
serializers.

## The Bin

Records in the Bin — and e-way bills whose invoice is in the Bin — are absent
from lists and return `404` by id, exactly as if they did not exist. Restoring
one from the Bin makes it visible again.

## Webhooks

Webhooks tell you that something happened, with the event's id and the record
it concerns; you then fetch the record through this API. See
[webhooks.md](webhooks.md) for the events, the signature and the retry rules.
