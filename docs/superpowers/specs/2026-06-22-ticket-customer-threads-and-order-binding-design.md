# Customer Threads Switching, Agent-Initiated Threads & Order Binding — Design

**Date:** 2026-06-22
**Status:** Approved design (pre-implementation)

## Problem

Today a `Ticket` is a 1:1 mirror of a Gmail thread. Three gaps:

1. **No cross-thread navigation.** A customer naturally has many tickets
   (`Customer has_many :tickets` already exists), but the Ticket Detail page
   shows only the one ticket. An agent cannot see or jump to the same customer's
   other threads without going back to the index and searching.
2. **Threads can only be created by inbound Gmail sync.** With the email
   workflow, we (admin or AI agent) need to *proactively* start a new thread
   with a customer (e.g. an order-shipped notice), and when drafting a reply we
   need to choose between **replying in the current thread** or **opening a new
   thread**.
3. **No link between a thread and an order.** The right info panel lists *all*
   of the customer's orders; nothing records which order a given thread is
   about, even though agent-initiated threads are order-driven (the
   `reopened_reason` enum already has `order_shipped` / `order_delivered`).

Note: the "thread only fetches the latest message" concern was investigated and
is **not a bug** — `GmailSyncService#process_thread` stores every message in the
thread (`full_thread.messages.each`), and `TicketsController#show` loads them
all. No sync change is needed.

## Goals

1. On Ticket Detail, switch between all tickets (threads) of the same customer.
2. Draft-reply flow lets the agent choose **reply to current thread** or **open
   a new thread**; allow proactively creating a thread for a customer.
3. Bind a thread to **one** order (optional), with an explicit UI action to
   bind / change / clear the binding. Surface the bound order on the thread.

## Non-Goals

- No separate `EmailThread` model — **Ticket stays 1:1 with a Gmail thread.**
- No many-to-many thread↔order. A thread relates to **at most one** order.
- No change to the state machine, the scheduler, or the send window logic.
- No change to Gmail sync message ingestion.

## Decisions (from brainstorming)

- **Model shape:** keep `Ticket = Thread` 1:1.
- **Customer grouping for the switcher:** if `customer_id` present, group by
  `customer_id`; otherwise fall back to `customer_email` (scoped — see below).
- **Order relationship:** `Order 1:N Ticket` — a nullable `order_id` on tickets.
- **New-thread entry point:** in the Ticket Detail draft-reply area.
- **UI layout:** Option A — email-client 3-pane on desktop; bottom-sheet thread
  switcher on mobile.

## Data Model

### 1. `tickets.gmail_thread_id` becomes nullable

Agent-initiated threads have **no Gmail thread id until the first message is
sent**. Gmail assigns the thread id on send; we backfill it then.

- Drop `null: false` on `gmail_thread_id`.
- Replace the existing unique index
  `(email_account_id, gmail_thread_id)` with a **partial unique index** that
  only applies when `gmail_thread_id IS NOT NULL`, so multiple
  not-yet-sent threads can coexist:

  ```ruby
  add_index :tickets, [:email_account_id, :gmail_thread_id], unique: true,
            where: "gmail_thread_id IS NOT NULL",
            name: "index_tickets_on_email_account_id_and_gmail_thread_id"
  ```

- Model validation: `gmail_thread_id` uniqueness scoped to `email_account_id`,
  `allow_nil: true`. Drop the presence requirement.

### 2. `tickets.initiated_by` (new enum)

Distinguishes who started the thread, for UI tagging and for send routing.

- `add_column :tickets, :initiated_by, :integer, null: false, default: 0`
- `enum :initiated_by, { customer: 0, agent: 1 }`
- Backfill is unnecessary: all existing tickets are inbound → default `customer`
  (0) is correct.
- `GmailSyncService` keeps creating inbound tickets → `customer` (the default,
  no code change required). Agent-initiated tickets set `agent`.

### 3. `tickets.order_id` (new optional FK)

- `add_reference :tickets, :order, type: :uuid, null: true, foreign_key: true,
  index: true`
- `Ticket belongs_to :order, optional: true`
- `Order has_many :tickets, dependent: :nullify`
  (mirror the existing `Customer has_many :tickets, dependent: :nullify` —
  deleting an order must not delete support history).

### Resulting associations

```
EmailAccount 1:N Ticket
Customer     1:N Ticket   (optional)
Order        1:N Ticket   (optional)   ← new
Ticket       1:N Message
```

## Customer Thread Grouping

A single helper resolves "sibling threads of this customer":

```ruby
# app/models/ticket.rb
def customer_threads
  scope = email_account.company.tickets  # company-wide visibility
  if customer_id.present?
    scope.where(customer_id: customer_id)
  else
    scope.where(customer_id: nil, customer_email: customer_email)
  end
end
```

- Grouping is **company-scoped**, not limited to one `email_account`, so threads
  the customer has across the company's mailboxes are all reachable. (Requires
  `Company has_many :tickets, through: :email_accounts` — add if absent.)
- Ordering: `by_recency` (`last_message_at DESC`), current thread pinned/marked.
- The unlinked branch intentionally requires `customer_id IS NULL` on both sides
  so a half-linked set never mixes.

## New Thread / Reply Routing

### Draft-reply "reply target" control

In the draft-reply panel (shown for `new_ticket` / `draft`), a segmented
control:

- **Reply to current thread** (default) — unchanged behavior; the scheduled send
  uses `thread_id: ticket.gmail_thread_id` as today.
- **Open new thread** — reveals a **subject** field (defaults to a fresh subject,
  not `Re: …`) and an optional **order** selector. On save this creates a *new*
  Ticket for the same customer rather than editing the current one.

### Creating an agent-initiated thread

A new `Ticket` is built with:

- `email_account` = current account, `customer_id` / `customer_email` copied from
  the originating ticket (or chosen customer),
- `initiated_by: :agent`,
- `gmail_thread_id: nil`,
- `status: :draft`, `draft_reply` = composed body, `subject` = chosen subject,
- `order_id` = optional bound order.

It then flows through the normal state machine
(`draft → draft_confirmed → closed`). The agent confirms and it schedules like
any other ticket.

### Send behavior for a thread with no `gmail_thread_id`

`SendScheduledEmailJob` currently always passes `thread_id:
ticket.gmail_thread_id`. Change: when `gmail_thread_id` is blank, send as a
**new** Gmail message (omit `thread_id` / pass nil), then **persist the returned
Gmail thread id and message id** onto the ticket so subsequent syncs and
customer replies attach to it correctly. The created `Message` record is stored
as today. No new-thread send needs `Re:` subject munging.

`GmailService#send_message` must return (or be adjusted to return) the Gmail
thread id of the sent message so we can backfill `ticket.gmail_thread_id`.

## Order Binding (UX action)

### Action

- The Ticket Detail right panel shows a **"Thread's order"** card:
  - bound → shows order number, total, fulfillment status, with a **Change**
    link;
  - unbound → shows a **Bind order** button.
- Clicking opens an **order picker modal** (same pattern as the existing
  `customer-search-modal` Stimulus controller):
  - lists the customer's orders (most recent first), searchable by order number
    / line-item; pre-selects the currently bound order;
  - includes a **"No order"** row to clear the binding.
- New-thread creation reuses the same picker inline to set the order up front.

### Persistence

- New route `PATCH /tickets/:id/bind_order` (member), body `order_id` (UUID or
  blank to clear).
- `TicketsController#bind_order` validates the order belongs to the ticket's
  customer (guard against binding another customer's order), sets `order_id`,
  responds with a Turbo Stream / redirect updating the card and the thread-list
  order tag.

### Surfacing

- Thread list item (desktop left rail, mobile bottom sheet) shows a small
  `📦 #<order_number>` tag when bound.
- Info panel keeps listing all customer orders, but the bound order is visually
  highlighted.

## UI / UX (Option A)

### Desktop — 3-pane

`[ thread list rail | conversation + draft | customer/order info ]`

- **Left rail:** customer header (avatar, name, email), thread count, **Open new
  thread** button, then the customer's threads with subject, snippet, status
  badge, `initiated_by` tag (`📤 us` / `⚡ customer-reply`), order tag, time;
  active thread highlighted.
- **Center:** subject + status header, status-transition buttons, message list
  (all messages, newest first as today), draft-reply panel with the reply-target
  segmented control and the AI-agent instruction box.
- **Right:** **Thread's order** binding card (top), customer details, orders /
  fulfillment timeline (existing `_info_panel` content).

### Mobile — bottom sheet switcher

- Sticky top customer bar with a **Switch (n)** button and a **current thread**
  summary; quick buttons for **Open new thread** and **Customer/Order info**.
- Tapping **Switch** opens a **bottom sheet** (≈80% height, dimmed backdrop)
  containing the full thread list (same content as the desktop rail) plus
  **Open new thread**; tapping a thread switches and closes the sheet.
- Order binding reachable from the collapsible info panel, opening the same
  order picker modal.

Visual prototype: `tmp/preview/index.html` (served during brainstorming) —
desktop/mobile × option toggles, interactive bottom sheet and order modal.

## Controller / Routes

```ruby
resources :tickets do
  member do
    patch :bind_order        # new
    # existing: search_customers, link_customer, instruct_agent, ...
  end
end
```

- `TicketsController#show` additionally loads `@customer_threads` (via
  `@ticket.customer_threads`) for the switcher.
- New-thread creation: a dedicated `POST /tickets` create action (params:
  `customer_id` / `customer_email`, `subject`, `draft_reply`, optional
  `order_id`) that builds an `initiated_by: :agent`, `gmail_thread_id: nil`,
  `status: :draft` ticket. Kept separate from the draft `update` path so the two
  flows stay readable.
- `bind_order` member action as above.
- API parity (`Api::V1::TicketsController`) is **out of scope** for this change
  unless the agent needs to create threads via API — flagged for the plan, not
  assumed.

## Edge Cases

- **Unlinked customer (no `customer_id`):** switcher groups by `customer_email`;
  binding an order requires a linked customer (orders hang off `Customer`), so
  the order card prompts to link the customer first when unlinked.
- **Two not-yet-sent agent threads:** allowed (partial unique index); each gets
  its Gmail thread id on send.
- **Customer replies into an agent-initiated thread after send:** normal sync
  reopen logic applies once `gmail_thread_id` is backfilled.
- **Order bound then order deleted:** `dependent: :nullify` leaves the ticket
  intact with `order_id = NULL`.
- **Binding an order from a different customer:** rejected by the controller
  guard.

## Testing (per project 95%+ requirement)

- **Model specs:** nullable `gmail_thread_id` + partial-unique validation;
  `initiated_by` enum; `order` association + `dependent: :nullify`;
  `customer_threads` grouping (linked vs email-fallback, company scope).
- **Request specs:** `bind_order` (success, clear, cross-customer rejection);
  new-thread creation (agent-initiated ticket fields); `show` exposes
  `@customer_threads`.
- **Job spec:** `SendScheduledEmailJob` sends as new Gmail thread when
  `gmail_thread_id` is nil and backfills the returned thread id.
- **System specs:** desktop thread switching; mobile bottom-sheet switch;
  reply-target toggle reveals subject/order and creates a new thread; order
  binding via modal updates the card and the thread-list tag.

## Migration & Rollout

1. Migration: nullable `gmail_thread_id` + partial unique index swap;
   add `initiated_by`; add `order_id` reference. (UUID PKs throughout.)
2. No data backfill required (defaults cover existing rows).
3. Ship behind normal PR flow to `staging`.
