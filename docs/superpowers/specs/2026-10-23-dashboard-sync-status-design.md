# Dashboard Sync Status & Manual Sync — Design

Date: 2026-10-23
Status: Draft, waiting for user approval

## Intent

Every number on the Dashboard is computed live from the DB. How fresh a number
is depends entirely on four background syncs that run every 30–60 minutes.
Today the user can't tell when the data was last updated, can't refresh it on
demand, and never hears about a failed sync: every sync job rescues its errors
and only writes them to the log. For example, Meta spend sat at $0 for two days
on 2026-10-21 before anyone noticed.

The user wants three things:
1. See **when** each part of the dashboard was last updated, for both automatic
   and manual syncs.
2. Trigger a sync **on demand** from the dashboard.
3. Have a **status that persists** across page refreshes and navigation until
   everything has finished. Failures stay visible, **with the error reason**,
   until the user has looked at them.

## Goals

- A status badge next to the date-range controls on the Dashboard, plus a
  **Sync** button.
- Clicking the badge opens a **drawer**: right-side on desktop, a bottom sheet
  on mobile. The user chose option B, and the mockup is in
  `.superpowers/brainstorm/` (`sync-status-layout.html`,
  `sync-status-mobile.html`).
- The drawer shows one row per data source with its current state, its recent
  sync history (time, automatic or manual, success or failure), and the error
  message for failures.
- Both automatic (scheduled) and manual syncs are recorded and shown.

## Non-goals

- No change to the sync logic itself: what is fetched, the lookback windows,
  or the schedules.
- No email, push, or Slack notifications. The status shows up only on the
  Dashboard.
- No status UI on other pages yet. Ad Campaigns and Orders keep their existing
  sync buttons.

## Anti-goals (would be a failure even if it technically works)

- The status says "updated" while a sync actually failed or silently skipped
  work.
- Pressing Sync repeatedly piles up duplicate jobs.
- The drawer blocks reading the dashboard numbers on desktop.
- One user acknowledging a failure hides it for other users.

## Data sources (the 4 rows)

| Row | Feeds | Job(s) | Schedule | Unit of work |
|---|---|---|---|---|
| Shopify revenue / order metrics | Revenue breakdown, Orders section | `SyncShopifyMetricsJob` | hourly | per Shopify store |
| Shopify orders (shipping) | Shipping section | `SyncAllShopifyOrdersRecurringJob` (scheduled) / `SyncAllShopifyOrdersJob` (manual) | hourly, plus webhooks | per Shopify store |
| Meta ads | Advertising (Meta) | `SyncAdMetricsJob` (account-level `AdDailyMetric`, the only Meta table the Dashboard reads) | every 30 min | per Meta ad account |
| Google ads | Advertising (Google) | `SyncGoogleAdMetricsJob` | hourly | per Google ad account |

Shopify webhooks update individual orders in real time. They are **not**
recorded as sync runs; only the job runs are.

`SyncAdCampaignsJob` and `SyncAdCreativesJob` feed the Ad Campaigns and
Creative Analysis pages, not the Dashboard, so they are **not** among the four
rows. *(Claude's call.)*

**Runs started from elsewhere.** The same jobs are also queued by the Ad
Campaigns, Orders, Packages, and Shipments sync buttons, and by the OAuth
connect backfills. Every run of the four jobs is recorded. *(Claude's call.)*
- Runs from the scheduler are labelled 自動.
- Anything a user started is labelled 手動, whichever page it came from.
- Any running run in scope disables the Dashboard Sync button, including a
  long backfill.

To make this work, each job gains an optional trigger argument, defaulting to
auto. `SyncShopifyMetricsJob` and `SyncAdMetricsJob` also gain optional
store, account, or company scoping arguments, so the Dashboard can enqueue a
scoped manual run.

## Behaviour (as decided with the user)

### Badge states
Runs are recorded per unit of work: one per store or ad account. A **source's**
state in scope rolls up its units. *(Claude's call.)*
- **Failed** if any unit's latest run failed. The drawer row lists the failing
  stores or accounts, nested under it, each with its error.
- **Running** if any unit is running.
- Otherwise **succeeded**, with its time being the oldest latest-success among
  its units.
- "N 項" counts sources, so N is at most 4.

- **Green**: "已更新 · X 分鐘前". Every source in scope succeeded on its latest
  run. X is the time since the **oldest** latest-success among the sources, so
  the badge never overstates freshness.
- **Yellow**: "同步中 n/4…". At least one source in scope has a run in
  progress.
- **Red**: "N 項同步失敗". At least one source's latest run failed **and** this
  user has not acknowledged that failure.
- Precedence: red > yellow > green.

### Failure lifecycle
- A failure stays red until either:
  1. **this user** opens the drawer and clicks "知道了，隱藏". The
     acknowledgement is **per user** and does not hide anything for other
     users. It covers the **source and error reason** *(user decision)*:
     - Later runs of the same source that fail with the **same** error stay
       hidden for that user.
     - A failure with a **different** error turns it red again.
     - Once the source succeeds, the acknowledgement no longer matters. A
       later failure turns it red again, even with the same error.

     When a source covers several stores or accounts, "same error" means the
     same set of failing units with the same error messages. Treat messages as
     equal after stripping volatile parts like request IDs and timestamps.
     The normalisation rule is the builder's call; or
  2. the **same source's next run succeeds**. It then clears automatically
     for everyone, and nobody needs to click.
- The row in the drawer keeps showing the failure in its history, but it no
  longer turns the badge red.

### Sync button
- Enqueues the 4 sources for the stores and ad accounts in the current scope
  (see Scope).
- While any manual or automatic run for the scope is in progress, the button is
  disabled. This prevents duplicate pile-ups.
- Manual runs are labelled "手動" in the history, and scheduled runs "自動".

### Live updates
- While the badge is yellow, the page polls a small status endpoint, for
  example every 5 s, and re-renders the badge and the drawer.
- Polling stops once nothing is running.
- The poll does **not** reload the dashboard numbers.
- **Permissions** *(Claude's call)*: anyone who can view the Dashboard can
  press Sync and acknowledge. This matches the existing Ad Campaigns and
  Orders sync buttons, which only check page permission. Manual runs are
  scoped to what that user sees on the Dashboard.
- Builder's call: whether to offer a "重新整理數字" link once a manual sync
  finishes.
- Action Cable is **not** an option: production `config/cable.yml` uses a redis
  adapter, and no redis is provisioned.

### Persistence
- Status lives in the DB, so it survives page refreshes, navigation, and other
  devices.
- The drawer's open/closed state is per page view only.

### Scope
- The badge and drawer follow the Dashboard's store selector and view group:
  - Shopify rows cover the selected store, or all visible stores when no store
    is selected.
  - Ad rows cover the ad accounts the dashboard itself counts. Reuse
    `DashboardMetricsService`'s scoping: group or company, narrowed by store.
- **Expired tokens count as failures** *(user decision)*. Today the jobs skip
  an ad account whose token has expired with `next if account.token_expired?`,
  and nothing records it. From now on, that skip is recorded as a **failed**
  run with a clear reason such as "token expired, reconnect the ad account".
  Like any failure, it turns the badge red, can be acknowledged, and appears in
  the drawer. Only accounts in the current company/scope count.

## History & retention (Claude's call, user did not object)
- The drawer shows the latest **5** runs per source.
- Run records older than **7 days** are purged by a recurring cleanup.

## How it gets made (Claude's calls, following the existing stack)
- Rails, Hotwire, Stimulus, Tailwind. No new gems.
- A new table records each sync run per unit of work (store or ad account),
  with:
  - source
  - target
  - trigger (auto or manual)
  - status (running, succeeded, failed)
  - started and finished timestamps
  - error class and message
  - a link to the company
- A second table records per-user acknowledgements of failed runs. UUID
  primary keys, per project rules.
- The four jobs record a run around each unit of work. The existing
  per-account `rescue` blocks are where the failure gets captured. Their
  current behaviour (log and continue with the next account) stays.
- A run row stuck in "running" (for example after a container restart
  mid-job) must not block the Sync button forever. Treat runs older than a
  timeout as failed or stale. The builder picks a sensible timeout per source.
  An OAuth backfill can run much longer than an incremental run.
- Drawer markup can follow the existing `thread_sheet_controller.js`
  open/close pattern.
- Tests must cover models, the request (sync action, status endpoint,
  acknowledge), the job recording (success, failure, skip), and a **system
  spec** for the badge, drawer, and acknowledge flow, since this is
  Turbo/Stimulus UI. Coverage stays ≥ 95%.

## Open questions for the user
- None. Both questions from the builder check were answered on 2026-10-23.
