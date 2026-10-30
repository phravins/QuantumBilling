# QuantumBilling webhooks

Webhooks tell your systems that something happened — an invoice was created or
paid, an e-way bill was generated — as it happens, so they don't have to poll.

An **owner** manages them under **Settings › Webhooks**, per business. Each
endpoint has its own URL, its own signing secret and its own list of events.

## Events

Every event is **thin**: it says what happened and to which record, and nothing
else.

```json
{
  "id": "evt_Qm9yZXN0IGd1bXAgZmFj",
  "type": "invoice.paid",
  "created_at": "2026-10-30T14:05:11Z",
  "data": {"object": "invoice", "id": 42}
}
```

To get the record, call the [API](api.md) — `GET /api/v1/invoices/42` — with a
key from the same business. That way an event never carries more than your API
key is allowed to read, and you always get the record as it is now, not as it
was when the event was queued.

| Event | `data.object` | When |
|---|---|---|
| `invoice.created` | `invoice` | An invoice is created (in the app, by the API, or by a recurring profile) |
| `invoice.updated` | `invoice` | An invoice is edited |
| `invoice.paid` | `invoice` | A payment is reconciled against an invoice |
| `invoice.e_invoice_generated` | `invoice` | An IRN is registered |
| `invoice.e_invoice_failed` | `invoice` | E-invoice registration fails |
| `client.created` | `client` | A client is added |
| `client.updated` | `client` | A client is edited |
| `e_way_bill.generated` | `e_way_bill` | An e-way bill is generated |
| `e_way_bill.cancelled` | `e_way_bill` | An e-way bill is cancelled |
| `credit_note.created` | `credit_note` | A credit or debit note is raised |
| `webhook.test` | `endpoint` | **Send test** on the webhooks page |

## The request

```
POST <your URL>
content-type: application/json
user-agent: QuantumBilling-Webhook/2
x-quantumbilling-event: invoice.paid
x-quantumbilling-event-id: evt_Qm9yZXN0IGd1bXAgZmFj
x-quantumbilling-timestamp: 1793369111
x-quantumbilling-signature: t=1793369111,v1=5f2b…
```

Answer with any **2xx within 10 seconds**. Do slow work after you've answered.

## Verifying a delivery

Anyone who learns your URL can post to it, so check every request before you
trust it:

1. Split `x-quantumbilling-signature` on `,`. The `t=` part is the timestamp;
   each `v1=` part is a signature. There are two `v1=` values for 24 hours after
   a secret is rotated.
2. Refuse the request if `t` is more than **5 minutes** from your clock. This
   stops a captured request being replayed later.
3. Compute `HMAC-SHA256(secret, t + "." + raw_body)` as lowercase hex. Use the
   **raw bytes** you received; parsing and re-encoding the JSON changes them.
4. Accept the request if it matches **any** `v1` value. Use a constant-time
   comparison.
5. **Drop repeats:** keep the `id`s you've already handled and ignore one you've
   seen. The same event can arrive more than once — after a timeout, or when
   an owner presses **Resend** — and always carries the same `id`.

```python
import hmac, hashlib, time

def verify(raw_body: bytes, header: str, secret: str, tolerance=300) -> bool:
    parts = [p.split("=", 1) for p in header.split(",")]
    if not parts or parts[0][0] != "t":
        return False
    timestamp = parts[0][1]
    if abs(time.time() - int(timestamp)) > tolerance:
        return False
    expected = hmac.new(secret.encode(), f"{timestamp}.".encode() + raw_body,
                        hashlib.sha256).hexdigest()
    return any(k == "v1" and hmac.compare_digest(v, expected) for k, v in parts[1:])
```

```js
const crypto = require("crypto");

function verify(rawBody, header, secret, tolerance = 300) {
  const parts = header.split(",").map((p) => p.split("="));
  if (parts[0]?.[0] !== "t") return false;
  const t = parts[0][1];
  if (Math.abs(Date.now() / 1000 - Number(t)) > tolerance) return false;
  const expected = crypto.createHmac("sha256", secret).update(`${t}.`).update(rawBody).digest("hex");
  return parts.slice(1).some(([k, v]) => k === "v1" && v.length === expected.length &&
    crypto.timingSafeEqual(Buffer.from(v), Buffer.from(expected)));
}
```

## Retries and switching off

| Your answer | What happens |
|---|---|
| 2xx | Delivered. |
| 408, 429, 5xx, timeout, connection refused | Retried after 30 s, 2 min, 10 min, 30 min, 1 h, 3 h, 6 h and 12 h — nine tries over about a day. Every retry sends the **same body** and the **same event id**. |
| 410 Gone | The delivery fails and the endpoint is **switched off**. |
| Any other 4xx | The delivery fails at once: sending the same request again can't change the answer. |

Ten deliveries that end in failure, one after another, switch the endpoint off.
The owners get a notification. Fix the receiver, press **Send test**, then
**Switch on**; the failure count starts again from zero.

The webhooks page lists each endpoint's latest 50 deliveries, with the status
and the HTTP code of the last try, and **Resend** for any of them. What your
server answered is never stored.

## Secrets

The secret is created by QuantumBilling, not typed in. It's shown **once**,
when the endpoint is added or its secret is rotated; afterwards only an
encrypted copy is kept. **Rotate secret** issues a new one. The old secret
keeps signing alongside it for 24 hours, so you can deploy the new one without
missing events.

## Where requests can go

Endpoint URLs must be `https://`. Addresses inside the server's own network
(loopback, private ranges, link-local and cloud metadata) are refused. The
check happens when the URL is saved and again on every delivery, which connects
to exactly the address that was checked. Redirects are not followed.

## Endpoints from before v2

If this business had a webhook URL under **Settings › Integrations**, it became
its first endpoint, marked **legacy format**. It keeps receiving
`invoice.created` and `invoice.paid` in the shape it always had, plus an `id`:

```json
{"id": "evt_…", "event": "invoice.paid", "payload": {"invoice_id": 42, "amount": 1180}, "sent_at": "…"}
```

It's still signed with `x-quantumbilling-signature: sha256=<hex>`, an
HMAC-SHA256 of the body alone. When you're ready, update the receiver to the
format above and press **Rotate secret**: that moves the endpoint to the thin
format and timestamped signatures.
