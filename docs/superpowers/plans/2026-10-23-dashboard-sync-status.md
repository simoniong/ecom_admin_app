# Dashboard Sync Status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record every Dashboard-feeding sync run, show its status in a badge and drawer on the Dashboard, and add a manual Sync button.

**Architecture:**
- A `SyncRun` row is written around each unit of work (one per store or ad account) inside the four existing sync jobs.
- A `SyncStatus` service rolls those rows up per source for the Dashboard's current scope, and applies per-user `SyncAcknowledgement`s.
- New actions on `DashboardController` serve the badge and drawer as a Turbo Frame. A Stimulus controller reloads that frame every 5 s while something is running. No Action Cable.

**Tech Stack:** Rails 8.1, PostgreSQL (UUID PKs), Solid Queue, Hotwire (Turbo Frames + Stimulus), Tailwind, RSpec + FactoryBot + Capybara.

**Spec:** `docs/superpowers/specs/2026-10-23-dashboard-sync-status-design.md`

## Global Constraints

- All new tables use UUID primary keys (`id: :uuid`); foreign keys are `t.uuid` / `references ..., type: :uuid`.
- The four sources, with their keys:
  - `shopify_metrics`: `SyncShopifyMetricsJob`
  - `shopify_orders`: `SyncAllShopifyOrdersRecurringJob`, `SyncAllShopifyOrdersJob`
  - `meta_ads`: `SyncAdMetricsJob`
  - `google_ads`: `SyncGoogleAdMetricsJob`
- Triggers are `"auto"` for scheduled runs and `"manual"` for anything a user started, including OAuth backfills.
- Existing job behaviour (log the error and continue with the next unit) must not change. Recording must never make a job raise where it didn't before.
- Expired-token skips are recorded as **failed** runs with the message `"Token expired — reconnect this ad account"`.
- Badge precedence is red > yellow > green.
  - "N 項同步失敗" counts sources (at most 4).
  - "同步中 n/4" counts running sources.
  - Green shows the time since the **oldest** latest-success among the sources.
- Acknowledgements are per user. An acknowledgement hides a failure only while **all** of these hold:
  - same source
  - same failure signature (the set of failing units plus their normalised messages)
  - no success since the acknowledgement was made
- The drawer shows the latest **5** runs per source. Runs older than **7 days** are purged daily.
- Stale "running" rows count as failed with message `"Interrupted — no result after N minutes"`. Thresholds in minutes:
  - `shopify_metrics` 15
  - `shopify_orders` 120
  - `meta_ads` 15
  - `google_ads` 120
- Polling interval: 5 s, only while the status is running. Polling never reloads `dashboard_metrics`.
- UI copy exists in `en`, `zh-CN`, and `zh-TW` (`config/locales/*.yml` under `dashboard.sync`).
- Desktop: right-side drawer. Mobile (< `sm`): bottom sheet with a dimmed backdrop. Mockup: `.superpowers/brainstorm/*/content/sync-status-*.html`.
- Coverage ≥ 95%. RuboCop omakase clean. The Turbo UI ships with a system spec in the same commit.

## Review Focus

1. **A job is killed mid-run (deploy/container restart) and leaves a `running` row.** The badge must not stay yellow forever, and Sync must be re-enabled after the stale threshold. Test: Task 3 `"treats a running row past its threshold as failed"`.
2. **The user switches the store selector while a failure is acknowledged.** The failing set in the new scope differs, so the badge may legitimately turn red again. It must not raise, and must not hide a failure from a store the ack never covered. Test: Task 3 `"an ack made in one store scope does not hide a different failing set"`.
3. **The same error message arrives with a volatile request id or timestamp.** It must still count as the "same error". Test: Task 1 `"normalises volatile parts of error messages"`.
4. **A company with no stores or no ad accounts at all, or a source that has never run.** The badge must render (a "never synced" state for that row) with no exceptions, and Sync must still work. Test: Task 3 `"reports never for a source with no runs"`, and Task 4 `"renders status for a company with no stores"`.
5. **Double-clicking Sync or two users clicking at once.** The second request must not enqueue a second batch. Test: Task 4 `"does not enqueue when a run in scope is already running"`.

---

### Task 1: `SyncRun` and `SyncAcknowledgement` models

**Files:**
- Create: `db/migrate/<ts>_create_sync_runs.rb`, `db/migrate/<ts>_create_sync_acknowledgements.rb`
- Create: `app/models/sync_run.rb`, `app/models/sync_acknowledgement.rb`
- Modify: `app/models/company.rb`, `app/models/user.rb` (add `has_many ..., dependent: :delete_all`)
- Create: `spec/factories/sync_runs.rb`, `spec/factories/sync_acknowledgements.rb`
- Test: `spec/models/sync_run_spec.rb`, `spec/models/sync_acknowledgement_spec.rb`

**Interfaces:**
- Produces:
  - `sync_runs` table. Columns:
    - `company_id` uuid, not null, FK
    - `source` string, not null
    - `target_type` string, not null
    - `target_id` uuid, not null (polymorphic: `ShopifyStore` or `AdAccount`)
    - `trigger` string, not null
    - `status` string, not null
    - `started_at` datetime, not null
    - `finished_at` datetime
    - `error_message` text
    - timestamps

    Index: `[:company_id, :source, :target_type, :target_id, :started_at]`.
  - `SyncRun::SOURCES = %w[shopify_metrics shopify_orders meta_ads google_ads]`
  - `SyncRun::STALE_AFTER = { "shopify_metrics" => 15.minutes, "shopify_orders" => 120.minutes, "meta_ads" => 15.minutes, "google_ads" => 120.minutes }`
  - `enum :status, { running: "running", succeeded: "succeeded", failed: "failed" }` and `enum :trigger, { auto: "auto", manual: "manual" }, prefix: true`
  - `SyncRun.track(source:, target:, trigger:) { ... } -> block's value`
    - First deletes any placeholder rows for the same (source, target). A placeholder is a `running`, `trigger: "manual"` row with no `finished_at`, pre-created by the Dashboard Sync action in Task 4.
    - Creates a `running` row with `company_id` taken from `target.company_id`.
    - Yields, then marks the row `succeeded`.
    - On any `StandardError`, marks it `failed` with `"#{e.class}: #{e.message}"` (truncated to 2,000 chars) and **re-raises**.
  - `SyncRun.record_failure(source:, target:, trigger:, message:) -> SyncRun`: one finished `failed` row (`started_at` = `finished_at` = now).
  - `SyncRun#stale? -> Boolean`: running and `started_at < STALE_AFTER[source].ago`.
  - `SyncRun#effective_status -> "running" | "succeeded" | "failed"`: `"failed"` when stale.
  - `SyncRun#effective_error -> String or nil`: the interrupted message when stale.
  - `SyncRun.normalize_error(message) -> String`: strips UUIDs, hex ids of 16+ chars, ISO timestamps, and digit runs of 6+, then squishes whitespace.
  - `SyncRun.purge_older_than(age) -> Integer`: deletes rows with `started_at < age.ago`.
  - `sync_acknowledgements` table. Columns:
    - `user_id` uuid, not null, FK
    - `company_id` uuid, not null, FK
    - `source` string, not null
    - `signature` string, not null
    - `acknowledged_at` datetime, not null
    - timestamps

    Unique index: `[:user_id, :company_id, :source]`.

- [ ] **Step 1: Write the failing model specs**

```ruby
# spec/models/sync_run_spec.rb
it "records a succeeded run around the block" do
  store = create(:shopify_store)
  result = SyncRun.track(source: "shopify_metrics", target: store, trigger: "auto") { :ok }
  run = SyncRun.last
  expect(result).to eq(:ok)
  expect(run).to have_attributes(status: "succeeded", trigger: "auto", target: store, company_id: store.company_id)
  expect(run.finished_at).to be_present
end

it "records a failed run and re-raises" do
  store = create(:shopify_store)
  expect {
    SyncRun.track(source: "shopify_orders", target: store, trigger: "manual") { raise ArgumentError, "boom" }
  }.to raise_error(ArgumentError, "boom")
  expect(SyncRun.last).to have_attributes(status: "failed", error_message: "ArgumentError: boom")
end

it "treats a running row older than its source threshold as stale/failed" do
  run = create(:sync_run, source: "meta_ads", status: "running", started_at: 16.minutes.ago)
  expect(run.stale?).to be(true)
  expect(run.effective_status).to eq("failed")
  expect(run.effective_error).to include("15")
end

it "normalises volatile parts of error messages" do
  a = SyncRun.normalize_error("PERMISSION_DENIED request_id=8f3a9c0b1d2e4f5a at 2026-10-23T03:00:01Z")
  b = SyncRun.normalize_error("PERMISSION_DENIED request_id=11aa22bb33cc44dd at 2026-10-23T04:00:09Z")
  expect(a).to eq(b)
end

it "track replaces a pre-created manual running row for the same target" do
  store = create(:shopify_store)
  create(:sync_run, source: "shopify_orders", target: store, trigger: "manual", status: "running", finished_at: nil)
  SyncRun.track(source: "shopify_orders", target: store, trigger: "manual") { :ok }
  expect(SyncRun.where(source: "shopify_orders", target: store).pluck(:status)).to eq([ "succeeded" ])
end

it "purges runs older than the given age" do
  create(:sync_run, started_at: 8.days.ago)
  keep = create(:sync_run, started_at: 1.day.ago)
  expect(SyncRun.purge_older_than(7.days)).to eq(1)
  expect(SyncRun.all).to contain_exactly(keep)
end
```

Also add `sync_acknowledgement_spec.rb`, which checks that the uniqueness validation on `[user_id, company_id, source]` and `source` inclusion in `SyncRun::SOURCES` both hold.

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/models/sync_run_spec.rb spec/models/sync_acknowledgement_spec.rb`
Expected: FAIL. The table and model are missing.

- [ ] **Step 3: Write the migrations and models to the Interfaces above.** Then run `bin/rails db:migrate` and check that `db/schema.rb` gains both tables.

- [ ] **Step 4: Run the specs to verify they pass**

Run: `bundle exec rspec spec/models/sync_run_spec.rb spec/models/sync_acknowledgement_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add db app/models spec/models spec/factories
git commit -m "feat(sync-status): add SyncRun and SyncAcknowledgement models"
```

---

### Task 2: Record runs in the four sync jobs

**Files:**
- Modify:
  - `app/jobs/sync_shopify_metrics_job.rb`
  - `app/jobs/sync_all_shopify_orders_recurring_job.rb`
  - `app/jobs/sync_all_shopify_orders_job.rb`
  - `app/jobs/sync_ad_metrics_job.rb`
  - `app/jobs/sync_google_ad_metrics_job.rb`
- Modify (pass `trigger: "manual"`): `ad_campaigns_controller.rb:15`, `google_ads_oauth_controller.rb:83`. The `SyncAllShopifyOrdersJob` call sites need no change because its default becomes manual.
- Test: `spec/jobs/sync_shopify_metrics_job_spec.rb`, `spec/jobs/sync_all_shopify_orders_job_spec.rb`, `spec/jobs/sync_all_shopify_orders_recurring_job_spec.rb`, `spec/jobs/sync_ad_metrics_job_spec.rb`, `spec/jobs/sync_google_ad_metrics_job_spec.rb`. Create the missing ones; stub only the external service class (`ShopifyAnalyticsService`, `SyncAllOrdersService`, `MetaAdsService`, `GoogleAdsService`), the same way existing specs stub Koala.

**Interfaces:**
- Consumes: `SyncRun.track`, `SyncRun.record_failure` (Task 1).
- Produces these job signatures. All are backward compatible.
  - `SyncShopifyMetricsJob#perform(days: 1, store_ids: nil, trigger: "auto")`
  - `SyncAllShopifyOrdersRecurringJob#perform`, which always uses trigger `"auto"`
  - `SyncAllShopifyOrdersJob#perform(shopify_store_id, full: false, trigger: "manual")`
  - `SyncAdMetricsJob#perform(ad_account_ids: nil, trigger: "auto")`
  - `SyncGoogleAdMetricsJob#perform(ad_account_id: nil, ad_account_ids: nil, company_id: nil, days: LOOKBACK_DAYS, trigger: "auto")`

- [ ] **Step 1: Write the failing job specs.** One example per behaviour, per job:

```ruby
it "records a succeeded auto run per store"            # SyncRun.where(source: "shopify_metrics", target: store).last.status == "succeeded", trigger "auto"
it "records a failed run when any date fails and still processes the other stores"
                                                        # stub sync_date to raise for store A only; A failed with the message, B succeeded, no exception escapes
it "limits to store_ids and records trigger manual"     # perform(store_ids: [a.id], trigger: "manual") -> only A has a run, trigger "manual"
# SyncAdMetricsJob / SyncGoogleAdMetricsJob:
it "records an expired-token account as failed with the reconnect message"
                                                        # account.token_expires_at = 1.day.ago -> failed run, error_message == "Token expired — reconnect this ad account"
it "limits to ad_account_ids"
# SyncAllShopifyOrdersJob: default trigger "manual"; Recurring job: trigger "auto"
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/jobs/sync_*_job_spec.rb`
Expected: FAIL. The runs are not recorded, and the unknown keywords are rejected.

- [ ] **Step 3: Implement the changes.**
  - Wrap each per-unit body in `SyncRun.track(source:, target:, trigger:)`, inside the existing `rescue`, so the log line is unchanged.
  - Replace each `next if account.token_expired?` with `SyncRun.record_failure(...)` followed by `next`.
  - In `SyncShopifyMetricsJob`, keep the per-date `rescue` but collect the messages. After the date loop, raise `SyncRun::Failed`, a new `StandardError` subclass defined in `sync_run.rb`, with `messages.join("; ")` so the store's run is failed. Add a per-store `rescue => e` that logs the same way, so the job keeps going.

- [ ] **Step 4: Run them to verify they pass**

Run: `bundle exec rspec spec/jobs spec/requests/ad_campaigns_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/jobs app/controllers spec/jobs
git commit -m "feat(sync-status): record sync runs in dashboard sync jobs"
```

---

### Task 3: `SyncStatus` service (scope, roll-up, acknowledgements)

**Files:**
- Modify: `app/services/dashboard_metrics_service.rb`. Extract the store/ad scope narrowing at lines 47–55 into a class method, and use it in `aggregate_metrics`.
- Create: `app/services/sync_status.rb`
- Test: `spec/services/sync_status_spec.rb`. Run `spec/services/dashboard_metrics_service_spec.rb` unchanged as a regression check.

**Interfaces:**
- Consumes: `SyncRun`, `SyncAcknowledgement` (Task 1).
- Produces:
  - `DashboardMetricsService.scopes_for(scope, shopify_store) -> [store_relation, ad_account_relation]`. This has exactly the semantics of today's lines 47–55.
  - `SyncStatus.new(company:, store_scope:, ad_scope:, user:)`, where `ad_scope` is split by platform: Meta for `meta_ads`, Google for `google_ads`.
  - `#sources -> Array<SyncStatus::Source>`, ordered as in `SyncRun::SOURCES`.
  - `SyncStatus::Source` is a `Data` with:
    - `key`
    - `state`: `:running`, `:failed`, `:succeeded`, or `:never`
    - `last_success_at`: the oldest latest-success across the units, or nil
    - `failures`: `Array<{ target_name:, message: }>`
    - `history`: the latest 5 `SyncRun`s across the units, newest first
    - `signature`: a String, or nil when not failed
    - `acknowledged`: Boolean
  - `#badge -> { state: :failed | :running | :ok | :never, failed_count:, running_count:, updated_at: }`
  - `#running? -> Boolean`
  - `#acknowledge!(source_key) -> SyncAcknowledgement`: upserts the row for (user, company, source) with the current signature and `Time.current`.
  - Units are `store_scope` stores for the two Shopify sources, and the platform's ad accounts for the ad sources. A unit's state is its latest run's `effective_status`.
  - Signature: SHA256 of the sorted `"#{target_type}:#{target_id}:#{SyncRun.normalize_error(msg)}"` lines over the failing units.
  - `acknowledged` is true when:
    - an ack exists with an equal signature, **and**
    - `ack.acknowledged_at` ≥ the newest "streak start" among the failing units.

    A unit's streak start is the `started_at` of its earliest failed run after its last succeeded run.

- [ ] **Step 1: Write the failing service spec**

```ruby
it "is succeeded with last_success_at = oldest latest success across units"   # two stores, successes at 10:00 and 10:30 -> 10:00
it "is running if any unit's latest run is running"                            # badge running_count == 1, running? true
it "is failed if any unit failed, listing the failing store and message"      # failures == [{ target_name: store_b.name, message: "X: y" }]
it "treats a running row past its threshold as failed"                         # meta_ads row started 20.minutes.ago -> state :failed, running? false
it "reports never for a source with no runs"                                   # state :never, badge never counts it as failed
it "hides an acknowledged failure for that user only"                          # acknowledge!(:google_ads) -> acknowledged true; other user false; badge failed_count 0 for user
it "re-raises a red when the error message changes after ack"                  # new failed run with different message -> acknowledged false
it "keeps it hidden when a later failure has the same (normalised) message"
it "re-raises a red after an intervening success, even with the same message"  # fail, ack, succeed, fail same msg -> acknowledged false
it "an ack made in one store scope does not hide a different failing set"      # ack with store_scope [A,B] failing {B}; new scope [A] failing {A} -> not acknowledged
it "limits units to the given scopes"                                          # runs for an out-of-scope store are ignored
it "shows at most 5 history rows newest first"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/services/sync_status_spec.rb`
Expected: FAIL. `SyncStatus` is not defined.

- [ ] **Step 3: Implement `SyncStatus` and `DashboardMetricsService.scopes_for` per Interfaces.** Load the latest runs per unit with one query per source (`DISTINCT ON (target_type, target_id) ... ORDER BY target_type, target_id, started_at DESC`) rather than one query per unit.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/services/sync_status_spec.rb spec/services/dashboard_metrics_service_spec.rb spec/requests/dashboard_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/services spec/services
git commit -m "feat(sync-status): roll up sync runs per source with per-user acks"
```

---

### Task 4: Dashboard sync endpoints

**Files:**
- Modify: `config/routes.rb`. Add these inside the locale/authenticated scope next to `root "dashboard#show"`:
  - `post "dashboard/sync" => "dashboard#sync", as: :dashboard_sync`
  - `get "dashboard/sync_status" => "dashboard#sync_status", as: :dashboard_sync_status`
  - `post "dashboard/sync_status/acknowledge" => "dashboard#acknowledge_sync", as: :dashboard_acknowledge_sync`

  They stay on `DashboardController`, so dashboard permissions and the store selector behave exactly as on `show`.
- Modify: `app/controllers/dashboard_controller.rb`
- Create: `app/views/dashboard/_sync_status.html.erb` (wrapped in `turbo_frame_tag "dashboard_sync_status"`). Task 5 fills in the markup; here it renders the badge text and the source rows plainly.
- Test: `spec/requests/dashboard_sync_spec.rb`

**Interfaces:**
- Consumes: `DashboardMetricsService.scopes_for`, `SyncStatus` (Task 3), and the job signatures from Task 2.
- Produces:
  - `private def sync_status_for_current_scope -> SyncStatus`, built from `selected_view_group || current_company` and `current_shopify_store`.
  - `sync`:
    - If `status.running?`, redirect to the root with alert `t("dashboard.sync.already_running")` and enqueue nothing.
    - Otherwise enqueue:
      - `SyncShopifyMetricsJob(store_ids:, trigger: "manual")`
      - `SyncAllShopifyOrdersJob(store_id, trigger: "manual")` per store
      - `SyncAdMetricsJob(ad_account_ids: meta_ids, trigger: "manual")`
      - `SyncGoogleAdMetricsJob(ad_account_ids: google_ids, trigger: "manual")`

      Skip any job whose id list is empty.
    - Before enqueueing, create a placeholder `running` row for each unit with `SyncRun.create!(source:, target:, company_id:, trigger: "manual", status: "running", started_at: Time.current)`. Task 1's `track` replaces it when the job starts. This turns the badge yellow at once and closes the double-click race.
    - Respond with a redirect to the root, keeping `range`, `start_date`, and `end_date`, with notice `t("dashboard.sync.enqueued")`.
  - `sync_status`: renders the `_sync_status` partial with no layout.
  - `acknowledge_sync`: takes `params[:source]` (must be in `SyncRun::SOURCES`; otherwise 422), calls `acknowledge!`, and re-renders the partial.

- [ ] **Step 1: Write the failing request spec**

```ruby
it "enqueues the four jobs scoped to the selected store with trigger manual"   # have_enqueued_job(SyncShopifyMetricsJob).with(store_ids: [store.id], trigger: "manual"), etc.
it "pre-creates running rows so the status is running immediately"
it "does not enqueue when a run in scope is already running"                  # existing running row -> no jobs, flash alert
it "renders the status partial inside the dashboard_sync_status frame"        # response.body includes 'turbo-frame id="dashboard_sync_status"'
it "acknowledges a source for the current user"                               # SyncAcknowledgement count +1, user == current user
it "rejects an unknown source"                                                # status 422
it "renders status for a company with no stores"                              # 200, no errors
it "does not include another company's runs"
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bundle exec rspec spec/requests/dashboard_sync_spec.rb`
Expected: FAIL. The routes are missing.

- [ ] **Step 3: Implement the routes, actions, and partial per Interfaces.**

- [ ] **Step 4: Run the specs to verify they pass**

Run: `bundle exec rspec spec/requests/dashboard_sync_spec.rb spec/requests/dashboard_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add config/routes.rb app/controllers/dashboard_controller.rb app/views/dashboard/_sync_status.html.erb spec
git commit -m "feat(sync-status): dashboard sync, status and acknowledge endpoints"
```

---

### Task 5: Badge and drawer UI with polling

**Files:**
- Modify: `app/views/dashboard/show.html.erb`. Put the badge, the Sync button, and the frame in the date-range row. On mobile they wrap to their own full-width row beneath the presets, as in the mockup.
- Modify: `app/views/dashboard/_sync_status.html.erb`. Add the full badge and drawer markup.
- Create: `app/javascript/controllers/sync_status_controller.js`
- Modify: `config/locales/en.yml`, `zh-CN.yml`, `zh-TW.yml`, under `dashboard.sync`
- Test: `spec/system/dashboard_sync_status_spec.rb`

**Interfaces:**
- Consumes: the routes and partial from Task 4.
- Produces:
  - Stimulus `sync-status` with:
    - targets `drawer`, `backdrop`
    - values `running: Boolean`, `interval: { type: Number, default: 5000 }`
    - actions `open`, `close`, `closeBackdrop`
  - On `connect` and on `runningValueChanged`, it starts or stops a timer that calls `this.element.closest("turbo-frame").reload()`. Re-rendering the frame reconnects the controller with the new `running` value.
  - The drawer's open state must survive a poll. Keep it in a module-level variable, restore it in `connect`, and clear it in `close`.
  - Drawer: `sm:` and up, a fixed right panel (`sm:inset-y-0 sm:right-0 sm:w-96`). Below `sm`, a bottom sheet (`inset-x-0 bottom-0 rounded-t-2xl max-h-[80vh] overflow-y-auto`) with backdrop `bg-black/35`.
  - Locale keys: `dashboard.sync`:
    - `button`
    - `updated_ago`: "已更新 · %{time}前" / "Updated %{time} ago"
    - `running`: "同步中 %{count}/4…"
    - `failed`: "%{count} 項同步失敗"
    - `never`
    - `title`
    - `acknowledge`: "知道了，隱藏"
    - `auto`, `manual`
    - `sources.shopify_metrics|shopify_orders|meta_ads|google_ads`
    - `enqueued`, `already_running`
    - `refresh_numbers`: a link that reloads the `dashboard_metrics` frame, shown when the badge is not running and a manual run finished in the last 10 minutes

- [ ] **Step 1: Write the failing system spec.** Use `sign_in_as` and the factories, as in `spec/system/dashboard_net_revenue_spec.rb`.

```ruby
it "shows a green badge with last update time"
it "opens the drawer with one row per source and its history labels 自動/手動"
it "shows a red badge with the error reason and hides it after 知道了" do
  create(:sync_run, source: "google_ads", target: google_account, status: "failed", error_message: "GoogleAdsError: PERMISSION_DENIED")
  visit authenticated_root_path
  expect(page).to have_content(I18n.t("dashboard.sync.failed", count: 1))
  click_on I18n.t("dashboard.sync.failed", count: 1)
  expect(page).to have_content("PERMISSION_DENIED")
  click_on I18n.t("dashboard.sync.acknowledge")
  expect(page).not_to have_content(I18n.t("dashboard.sync.failed", count: 1))
end
it "clicking Sync turns the badge to running and disables the button"         # perform_enqueued_jobs off; badge shows running text; button[disabled]
it "updates from running to done without a page reload"                       # running row -> click into page, then mark row succeeded in DB; within 7s badge shows updated_ago; same page (check a JS window marker)
it "keeps the drawer open across a poll"
it "uses a bottom sheet at phone width"                                        # page.driver.browser.manage.window.resize_to(375, 800); drawer has class 'bottom-0'
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bundle exec rspec spec/system/dashboard_sync_status_spec.rb`
Expected: FAIL. The badge markup is missing.

- [ ] **Step 3: Implement the markup, Stimulus controller, and locale keys per Interfaces.** Register the controller in `app/javascript/controllers/index.js` if the project registers controllers manually; check how `thread_sheet_controller` is registered and do the same.

- [ ] **Step 4: Run the specs to verify they pass**

Run: `bundle exec rspec spec/system/dashboard_sync_status_spec.rb spec/system/dashboard_net_revenue_spec.rb spec/requests/dashboard_sync_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/views/dashboard app/javascript/controllers config/locales spec/system
git commit -m "feat(sync-status): dashboard sync badge, drawer and polling"
```

---

### Task 6: Retention and full verification

**Files:**
- Modify: `config/recurring.yml`. Under `production:`, add:

  ```yaml
  purge_sync_runs:
    command: "SyncRun.purge_older_than(7.days)"
    schedule: every day at 5am
  ```
- Test: `spec/config/recurring_schedule_spec.rb`. If a spec that parses `recurring.yml` already exists, extend it; otherwise create a small one that asserts the `purge_sync_runs` entry and its command.

- [ ] **Step 1: Write the failing spec for the recurring entry.** Run it and confirm it fails.
- [ ] **Step 2: Add the entry.** Run the spec and confirm it passes.
- [ ] **Step 3: Run the full suite**

  Run: `bundle exec rspec`
  Expected: 0 failures, `Line Coverage:` ≥ 95%.
- [ ] **Step 4: Lint and security**

  Run: `bin/rubocop && bin/brakeman --no-pager -q && bin/importmap audit`
  Expected: no offenses, no warnings, no vulnerable packages.
- [ ] **Step 5: Commit**

  ```bash
  git add config/recurring.yml spec
  git commit -m "chore(sync-status): purge sync runs older than 7 days"
  ```
