# CS Agent Ticket API Documentation

Base URL: `https://{host}/api/v1`

## Authentication

All requests require a Bearer token in the `Authorization` header:

```
Authorization: Bearer {AGENT_API_KEY}
```

Unauthorized requests return `401`:

```json
{ "error": "Unauthorized" }
```

---

## Workflow

```
1. GET /tickets          → List all new (unprocessed) tickets
2. GET /tickets/:id      → Get ticket detail with customer, orders, fulfillments
3. POST /tickets/:id/draft_reply  → Submit draft reply, ticket transitions to "draft"
4. (Human reviews draft in admin UI → confirms → system schedules email send)
```

---

## Endpoints

### 1. List New Tickets

```
GET /tickets
```

Returns all tickets with `status: "new_ticket"`, ordered by most recent message first.

**Response** `200 OK`

```json
[
  {
    "id": "dc281958-9993-4b92-b99e-38a683e400d9",
    "subject": "Where is my order?",
    "status": "new_ticket",
    "customer_email": "jane@example.com",
    "customer_name": "Jane Doe",
    "draft_reply": null,
    "draft_reply_at": null,
    "last_message_at": "2026-04-05T10:30:00Z",
    "created_at": "2026-04-05T10:00:00Z",
    "messages": [
      {
        "id": "a1b2c3d4-...",
        "from": "jane@example.com",
        "to": "support@shop.com",
        "subject": "Where is my order?",
        "body": "Hi, I ordered 5 days ago and haven't received any tracking...",
        "sent_at": "2026-04-05T10:30:00Z"
      }
    ]
  }
]
```

---

### 2. Get Ticket Detail

```
GET /tickets/:id
```

Returns a single ticket with full context: messages, customer profile, orders, and fulfillment/tracking info. **Only returns tickets with `status: "new_ticket"`.**

**Response** `200 OK`

```json
{
  "id": "dc281958-9993-4b92-b99e-38a683e400d9",
  "subject": "Where is my order?",
  "status": "new_ticket",
  "customer_email": "jane@example.com",
  "customer_name": "Jane Doe",
  "draft_reply": null,
  "draft_reply_at": null,
  "last_message_at": "2026-04-05T10:30:00Z",
  "created_at": "2026-04-05T10:00:00Z",
  "messages": [
    {
      "id": "a1b2c3d4-...",
      "from": "jane@example.com",
      "to": "support@shop.com",
      "subject": "Where is my order?",
      "body": "Hi, I ordered 5 days ago and haven't received any tracking...",
      "sent_at": "2026-04-05T10:30:00Z"
    }
  ],
  "customer": {
    "id": "f5e6d7c8-...",
    "email": "jane@example.com",
    "first_name": "Jane",
    "last_name": "Doe",
    "phone": "+1234567890"
  },
  "orders": [
    {
      "id": "b2c3d4e5-...",
      "name": "#1042",
      "total_price": 59.99,
      "currency": "USD",
      "financial_status": "paid",
      "fulfillment_status": "fulfilled",
      "ordered_at": "2026-03-30T08:00:00Z",
      "fulfillments": [
        {
          "id": "c3d4e5f6-...",
          "status": "success",
          "tracking_number": "YT2412345678901",
          "tracking_company": "YunExpress",
          "tracking_url": "https://www.17track.net/en/track?nums=YT2412345678901",
          "tracking_status": "InTransit",
          "tracking_sub_status": "InTransit_PickedUp",
          "origin_country": "CN",
          "destination_country": "US",
          "shipped_at": "2026-03-31T12:00:00Z",
          "shopify_shipped_at": "2026-03-31T10:00:00Z",
          "delivered_at": null,
          "last_event_at": "2026-04-03T18:00:00Z",
          "latest_event_description": "Shipment departed from facility",
          "transit_days": 5
        }
      ]
    }
  ]
}
```

**Error** `404 Not Found` — ticket doesn't exist or is not in `new_ticket` status:

```json
{ "error": "Ticket not found or not in new status" }
```

---

### 3. Submit Draft Reply

```
POST /tickets/:id/draft_reply
```

Submit a draft reply for a ticket. Transitions ticket status from `new_ticket` → `draft`.

**Request Body** (`Content-Type: application/json`)

```json
{
  "draft_reply": "Hi Jane,\n\nThank you for reaching out! I've checked your order #1042 and it's currently in transit. Based on the latest tracking update, your package departed the shipping facility on April 3rd.\n\nDelivery typically takes 10-15 business days. You can track your package here: https://www.17track.net/en/track?nums=YT2412345678901\n\nPlease let me know if you have any other questions!\n\nBest regards"
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `draft_reply` | string | Yes | The draft reply content. Must not be blank. |

**Response** `200 OK`

```json
{
  "id": "dc281958-9993-4b92-b99e-38a683e400d9",
  "subject": "Where is my order?",
  "status": "draft",
  "customer_email": "jane@example.com",
  "customer_name": "Jane Doe",
  "draft_reply": "Hi Jane,\n\nThank you for reaching out! ...",
  "draft_reply_at": "2026-04-05T11:00:00Z",
  "last_message_at": "2026-04-05T10:30:00Z",
  "created_at": "2026-04-05T10:00:00Z",
  "messages": [...]
}
```

**Errors:**

| Status | Condition | Response |
|--------|-----------|----------|
| `404` | Ticket not found | `{ "error": "Ticket not found" }` |
| `422` | Ticket not in `new_ticket` status | `{ "error": "Ticket is not in new status" }` |
| `422` | `draft_reply` is blank | `{ "error": "Draft reply content is required" }` |
| `422` | Validation failure | `{ "error": "Validation failed", "details": [...] }` |

---

## Ticket Status Flow

```
new_ticket ──→ draft ──→ draft_confirmed ──→ closed
   │            (API)       (human only)     (auto, after email sent)
   │
   └──→ closed (if thread already has our reply when synced)
```

- **new_ticket**: Awaiting agent processing. Visible to the API.
- **draft**: Agent submitted a draft reply. Awaiting human review.
- **draft_confirmed**: Human approved the draft. Email is scheduled for send (timezone-aware, 8am–10pm recipient local time).
- **closed**: Email has been sent. If customer replies again, ticket reopens to `new_ticket`.

**The API can only perform the `new_ticket → draft` transition.**

---

## Data Model Reference

### Fulfillment Shipping Timestamps

| Field | Source | Description |
|-------|--------|-------------|
| `shopify_shipped_at` | Shopify | Shopify fulfillment creation time. This is when the merchant marked the order as shipped. Use this when communicating shipping dates to customers (matches what they see in the admin UI). |
| `shipped_at` | 17Track | First actual transit event time detected by the carrier (e.g. "collected", "picked up", "departed"). This is typically later than `shopify_shipped_at` because there's a delay between the merchant creating the fulfillment and the carrier scanning the package. May be `null` if 17Track hasn't detected any transit events yet. |

### Fulfillment Tracking Statuses

| Status | Description |
|--------|-------------|
| `NotFound` | No tracking info available yet |
| `InfoReceived` | Carrier received shipment info |
| `InTransit` | Package is in transit |
| `AvailableForPickup` | Ready for customer pickup |
| `OutForDelivery` | Out for final delivery |
| `DeliveryFailure` | Delivery attempt failed |
| `Delivered` | Successfully delivered |
| `Exception` | Shipment has an exception/issue |
| `Expired` | Tracking info expired |

### Common Financial Statuses (from Shopify)

`pending`, `authorized`, `paid`, `partially_paid`, `refunded`, `partially_refunded`, `voided`

### Common Fulfillment Statuses (from Shopify)

`fulfilled`, `partial`, `unfulfilled`, `restocked`
