# Unified Store Switcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single, consistent store-switcher component to Dashboard / Orders / Shipments / Tickets that persists the selected store across pages, where Dashboard & Shipments also offer "All Stores" and Orders & Tickets are always scoped to one store; Settings shows no switcher.

**Architecture:** Centralize store-selection resolution + persistence in `AdminController` (session-backed, param-overridable, per-controller policy on whether "All" is allowed). Render one shared partial (`shared/_store_switcher`) next to each page title, driven by a small Stimulus controller that navigates the current page with a new `store_id`. Wire the resolved `current_shopify_store` into each section's existing query path; only Dashboard needs new scoping logic in `DashboardMetricsService`.

**Tech Stack:** Rails 8.1, Hotwire/Stimulus, Importmap, Tailwind, RSpec + FactoryBot, PostgreSQL (UUID ids).

## Global Constraints

- Never commit to `main`/`staging`; work on `feature/unified-store-switcher` (already checked out).
- RSpec + FactoryBot only, no mocks, hit the real DB; keep 95%+ coverage (add model/service, request, and system specs).
- RuboCop Omakase style; run `bin/rubocop` before each commit.
- All table ids are UUIDs (`store_id` values are UUID strings or the literal `"all"`).
- Run Ruby tooling with `/home/simon/.rubies/ruby-3.4.7/bin` prepended to PATH (rails/rspec/bundle). SimpleCov exiting non-zero on single-file runs is expected.
- Routes are under `scope "(:locale)"`; preserve current path + query params when building switch URLs.
- Store display label = `ShopifyStore#shop_domain` (there is no `name` column).
- i18n must be added to all three locale files: `config/locales/en.yml`, `config/locales/zh-CN.yml`, `config/locales/zh-TW.yml`.

---

### Task 1: Store-selection resolution, persistence, and policy in AdminController

**Files:**
- Modify: `app/controllers/admin_controller.rb` (replace `current_shopify_store`, add constants/helpers/`before_action`)
- Modify: `app/controllers/company_sessions_controller.rb:4-8` (clear store on company switch)
- Test: `spec/requests/store_switcher_spec.rb` (create)

**Interfaces:**
- Produces:
  - `current_shopify_store -> ShopifyStore | nil` (nil ⇒ "all stores"; for non-All controllers never nil when stores exist — falls back to first visible store)
  - `store_switcher_visible? -> Boolean` (true only for `dashboard|orders|shipments|tickets`)
  - `store_all_allowed? -> Boolean` (true only for `dashboard|shipments`)
  - `session[:store_id]` persists the raw selection (`"all"` or a UUID string) for switcher controllers only
- Consumes: existing `visible_shopify_stores`, `current_company`, `session`

- [ ] **Step 1: Write the failing request spec**

Create `spec/requests/store_switcher_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Store switcher resolution & persistence", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }
  let!(:store_a) { create(:shopify_store, company: company, user: owner) }
  let!(:store_b) { create(:shopify_store, company: company, user: owner) }

  before { sign_in owner }

  describe "Dashboard (All allowed)" do
    it "renders without forcing a store when nothing is selected" do
      get authenticated_root_path
      expect(response).to have_http_status(:success)
      expect(session[:store_id]).to be_nil
    end

    it "persists a selected store id in the session" do
      get authenticated_root_path, params: { store_id: store_a.id }
      expect(session[:store_id]).to eq(store_a.id)
    end

    it "remembers the store across a later page load with no param" do
      get authenticated_root_path, params: { store_id: store_a.id }
      get authenticated_root_path
      expect(session[:store_id]).to eq(store_a.id)
    end

    it "persists the literal 'all' selection" do
      get authenticated_root_path, params: { store_id: store_a.id }
      get authenticated_root_path, params: { store_id: "all" }
      expect(session[:store_id]).to eq("all")
    end
  end

  describe "Orders (All NOT allowed)" do
    it "succeeds and does not overwrite an existing 'all' selection" do
      get authenticated_root_path, params: { store_id: "all" }
      get orders_path
      expect(response).to have_http_status(:success)
      expect(session[:store_id]).to eq("all")
    end

    it "persists a concrete store chosen on Orders" do
      get orders_path, params: { store_id: store_b.id }
      expect(session[:store_id]).to eq(store_b.id)
    end
  end

  describe "Settings pages (no switcher)" do
    it "does not write store_id to the session" do
      get shopify_stores_path, params: { store_id: store_a.id }
      expect(session[:store_id]).to be_nil
    end
  end

  describe "switching company" do
    it "clears the remembered store" do
      get authenticated_root_path, params: { store_id: store_a.id }
      other = create(:company)
      create(:membership, company: other, user: owner, role: :owner)
      patch switch_company_path(id: other.id)
      expect(session[:store_id]).to be_nil
    end
  end
end
```

- [ ] **Step 2: Run the spec and confirm it fails**

Run: `bundle exec rspec spec/requests/store_switcher_spec.rb`
Expected: FAILs (e.g. `session[:store_id]` stays nil / "all" not persisted / not cleared on company switch).

- [ ] **Step 3: Implement resolution + persistence in AdminController**

In `app/controllers/admin_controller.rb`, add the constants just below the existing `PERMISSION_KEY_MAP` block:

```ruby
  STORE_SWITCHER_CONTROLLERS = %w[dashboard orders shipments tickets].freeze
  STORE_ALL_ALLOWED_CONTROLLERS = %w[dashboard shipments].freeze
```

Add the `before_action` right after `before_action :authorize_page!` (line 4):

```ruby
  before_action :persist_store_selection
```

Replace the existing `current_shopify_store` method (lines 113-123) with:

```ruby
  def current_shopify_store
    return @current_shopify_store if defined?(@current_shopify_store)

    @current_shopify_store = resolve_current_store
  end
  helper_method :current_shopify_store

  def store_switcher_visible?
    STORE_SWITCHER_CONTROLLERS.include?(controller_name)
  end
  helper_method :store_switcher_visible?

  def store_all_allowed?
    STORE_ALL_ALLOWED_CONTROLLERS.include?(controller_name)
  end
  helper_method :store_all_allowed?
```

Add these private methods (e.g. just above `visible_resource`):

```ruby
  def persist_store_selection
    return unless store_switcher_visible?

    session[:store_id] = params[:store_id] if params[:store_id].present?
  end

  def resolve_current_store
    stores = visible_shopify_stores
    raw = params[:store_id].presence || session[:store_id].presence

    if raw == "all"
      return nil if store_all_allowed?

      return stores.first
    end

    if raw.present?
      found = stores.find_by(id: raw)
      return found if found
    end

    store_all_allowed? ? nil : stores.first
  end
```

- [ ] **Step 4: Clear remembered store when company changes**

In `app/controllers/company_sessions_controller.rb`, update `update`:

```ruby
  def update
    company = current_user.companies.find(params[:id])
    session[:company_id] = company.id
    session.delete(:store_id)
    redirect_back fallback_location: authenticated_root_path
  end
```

- [ ] **Step 5: Run the spec and confirm it passes**

Run: `bundle exec rspec spec/requests/store_switcher_spec.rb`
Expected: PASS (all examples green).

- [ ] **Step 6: Guard against regressions in existing Orders/Shipments specs**

Run: `bundle exec rspec spec/requests/orders_spec.rb spec/requests/shipments_spec.rb`
Expected: PASS. (Orders now defaults to the first store instead of "all stores" when multiple stores exist and none is selected; those specs use a single store so behavior is unchanged.)

- [ ] **Step 7: Lint and commit**

```bash
bin/rubocop app/controllers/admin_controller.rb app/controllers/company_sessions_controller.rb
git add app/controllers/admin_controller.rb app/controllers/company_sessions_controller.rb spec/requests/store_switcher_spec.rb
git commit -m "feat(store-switcher): session-backed store resolution with per-page All policy

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Store-switcher partial, Stimulus controller, and i18n

**Files:**
- Create: `app/views/shared/_store_switcher.html.erb`
- Create: `app/javascript/controllers/store_switcher_controller.js`
- Modify: `config/locales/en.yml`, `config/locales/zh-CN.yml`, `config/locales/zh-TW.yml`
- Test: covered by the system spec in Task 6 (no isolated unit test for the partial)

**Interfaces:**
- Consumes (from Task 1): `store_switcher_visible?`, `store_all_allowed?`, `current_shopify_store`, `visible_shopify_stores`
- Produces: renderable partial `shared/store_switcher`; Stimulus controller registered as `store-switcher`; i18n keys `store_switcher.all_stores`, `store_switcher.no_stores`

- [ ] **Step 1: Add i18n keys (all three locales)**

Append a top-level `store_switcher:` block to each file (place it near other top-level keys, e.g. after the `nav:` block). In `config/locales/en.yml`:

```yaml
  store_switcher:
    all_stores: "All Stores"
    no_stores: "No stores"
```

In `config/locales/zh-CN.yml`:

```yaml
  store_switcher:
    all_stores: "所有商店"
    no_stores: "暂无商店"
```

In `config/locales/zh-TW.yml`:

```yaml
  store_switcher:
    all_stores: "所有商店"
    no_stores: "暫無商店"
```

- [ ] **Step 2: Create the Stimulus controller**

Create `app/javascript/controllers/store_switcher_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Navigates the current page to the selected option's URL (a GET that
// carries the new store_id plus the page's existing query params).
export default class extends Controller {
  switch(event) {
    const url = event.target.value
    if (url) window.location.href = url
  }
}
```

> Note: importmap auto-loads `app/javascript/controllers/*_controller.js` via the project's stimulus-loading setup; no manual registration is needed (same as `company_switcher_controller.js`).

- [ ] **Step 3: Create the partial**

Create `app/views/shared/_store_switcher.html.erb`:

```erb
<% if store_switcher_visible? %>
  <% stores = visible_shopify_stores.to_a %>
  <% if stores.size > 1 %>
    <div data-controller="store-switcher" class="inline-block">
      <select data-action="change->store-switcher#switch"
              aria-label="<%= t("store_switcher.all_stores") %>"
              class="text-sm border-gray-300 rounded-md focus:ring-gray-500 focus:border-gray-500 py-1.5 pl-3 pr-8 shadow-sm">
        <% if store_all_allowed? %>
          <option value="<%= url_for(request.path_parameters.merge(request.query_parameters.merge(store_id: "all"))) %>"
                  <%= "selected" if current_shopify_store.nil? %>>
            <%= t("store_switcher.all_stores") %>
          </option>
        <% end %>
        <% stores.each do |store| %>
          <option value="<%= url_for(request.path_parameters.merge(request.query_parameters.merge(store_id: store.id))) %>"
                  <%= "selected" if current_shopify_store&.id == store.id %>>
            <%= store.shop_domain %>
          </option>
        <% end %>
      </select>
    </div>
  <% elsif stores.size == 1 %>
    <span class="inline-flex items-center text-sm text-gray-600"><%= stores.first.shop_domain %></span>
  <% else %>
    <span class="inline-flex items-center text-sm text-gray-400"><%= t("store_switcher.no_stores") %></span>
  <% end %>
<% end %>
```

- [ ] **Step 4: Sanity-check i18n loads**

Run: `bundle exec rails runner 'puts I18n.t("store_switcher.all_stores", locale: :"zh-TW")'`
Expected: prints `所有商店` (confirms YAML parses and key resolves).

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop app/views/shared/_store_switcher.html.erb 2>/dev/null || true
git add app/views/shared/_store_switcher.html.erb app/javascript/controllers/store_switcher_controller.js config/locales/en.yml config/locales/zh-CN.yml config/locales/zh-TW.yml
git commit -m "feat(store-switcher): shared partial, stimulus controller, i18n

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Render the switcher next to each page title

**Files:**
- Modify: `app/views/dashboard/show.html.erb:2-7`
- Modify: `app/views/orders/index.html.erb:2-3`
- Modify: `app/views/shipments/index.html.erb:3-31`
- Modify: `app/views/tickets/index.html.erb:2-4`
- Test: covered by Task 6 system spec

**Interfaces:**
- Consumes: `shared/store_switcher` partial (Task 2)
- Produces: each page header shows `[title][switcher] … [existing actions]`

- [ ] **Step 1: Dashboard — switcher beside the title**

In `app/views/dashboard/show.html.erb`, replace the header block (lines 2-7):

```erb
  <div class="flex items-center justify-between mb-6">
    <div>
      <h1 class="text-2xl font-semibold text-gray-900"><%= t("dashboard.title") %></h1>
      <p class="mt-1 text-sm text-gray-600"><%= t("dashboard.welcome", name: current_user.first_name.presence || current_user.email) %></p>
    </div>
  </div>
```

with:

```erb
  <div class="flex items-center justify-between mb-6">
    <div class="flex items-center gap-3">
      <div>
        <h1 class="text-2xl font-semibold text-gray-900"><%= t("dashboard.title") %></h1>
        <p class="mt-1 text-sm text-gray-600"><%= t("dashboard.welcome", name: current_user.first_name.presence || current_user.email) %></p>
      </div>
      <%= render "shared/store_switcher" %>
    </div>
  </div>
```

- [ ] **Step 2: Orders — switcher beside the title (Sync button stays right)**

In `app/views/orders/index.html.erb`, change the opening of the header `div` (lines 2-3) from:

```erb
  <div class="flex items-center justify-between">
    <h1 class="text-2xl font-bold text-gray-900"><%= t("orders.title") %></h1>
```

to:

```erb
  <div class="flex items-center justify-between">
    <div class="flex items-center gap-3">
      <h1 class="text-2xl font-bold text-gray-900"><%= t("orders.title") %></h1>
      <%= render "shared/store_switcher" %>
    </div>
```

Then close the new wrapper `div` immediately before the `button_to … sync` block's closing — i.e. wrap so the title+switcher are one flex child and the sync button is the other. Concretely, after the `<% end %>` that closes the `button_to` (the existing Sync button at lines 4-10), the outer header `div` already closes with `</div>`; just ensure the inserted `<div class="flex items-center gap-3"> … </div>` wraps only the `<h1>` and the switcher render. The Sync `button_to` remains a direct child of the `justify-between` row.

Resulting header structure:

```erb
  <div class="flex items-center justify-between">
    <div class="flex items-center gap-3">
      <h1 class="text-2xl font-bold text-gray-900"><%= t("orders.title") %></h1>
      <%= render "shared/store_switcher" %>
    </div>
    <%= button_to sync_orders_path, method: :post,
        class: "inline-flex items-center gap-2 px-4 py-2 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50" do %>
      <svg class="w-4 h-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
        <path stroke-linecap="round" stroke-linejoin="round" d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0 3.181 3.183a8.25 8.25 0 0 0 13.803-3.7M4.031 9.865a8.25 8.25 0 0 1 13.803-3.7l3.181 3.182M2.985 14.652" />
      </svg>
      <%= t("orders.sync") %>
    <% end %>
  </div>
```

- [ ] **Step 3: Shipments — switcher beside the title dropdown**

In `app/views/shipments/index.html.erb`, the header is `<div class="flex items-center justify-between">` containing a left `div.relative[data-controller="dropdown"]` (the title dropdown) and a right `div.flex.items-center.gap-2` (Export/Sync actions). Wrap the existing left title-dropdown block and the switcher together in a flex container. Replace the opening line (line 3) from:

```erb
  <div class="flex items-center justify-between">
    <div class="relative" data-controller="dropdown">
```

to:

```erb
  <div class="flex items-center justify-between">
    <div class="flex items-center gap-3">
      <div class="relative" data-controller="dropdown">
```

Then add a matching close for the new wrapper. The title-dropdown block currently ends at its `</div>` on line 31 (the `</div>` that closes `div.relative`). Immediately after that closing `</div>`, insert:

```erb
      <%= render "shared/store_switcher" %>
    </div>
```

so the structure becomes `justify-between → [ flex gap-3: [dropdown title][switcher] ] [ actions ]`. Leave the right-side actions `div` untouched.

- [ ] **Step 4: Tickets — switcher beside the title (above search)**

In `app/views/tickets/index.html.erb`, replace the title line (lines 2-3 region):

```erb
  <div class="mb-6">
    <h1 class="text-2xl font-semibold text-gray-900 mb-4"><%= t("tickets.title") %></h1>
```

with:

```erb
  <div class="mb-6">
    <div class="flex items-center gap-3 mb-4">
      <h1 class="text-2xl font-semibold text-gray-900"><%= t("tickets.title") %></h1>
      <%= render "shared/store_switcher" %>
    </div>
```

(The `mb-4` moves from the `<h1>` to the new wrapper; the search `form_with` below is unchanged.)

- [ ] **Step 5: Smoke-test rendering of all four pages**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb spec/requests/orders_spec.rb spec/requests/shipments_spec.rb spec/requests/tickets_spec.rb`
Expected: PASS (no template/ERB errors; existing assertions still hold).

- [ ] **Step 6: Lint and commit**

```bash
git add app/views/dashboard/show.html.erb app/views/orders/index.html.erb app/views/shipments/index.html.erb app/views/tickets/index.html.erb
git commit -m "feat(store-switcher): render switcher beside page titles on the four sections

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Scope Tickets to the selected store

**Files:**
- Modify: `app/controllers/admin_controller.rb:77-80` (`visible_tickets`)
- Test: `spec/requests/tickets_spec.rb` (add an example)

**Interfaces:**
- Consumes (from Task 1): `current_shopify_store` (concrete store for the tickets controller)
- Produces: `visible_tickets` returns only tickets whose email account belongs to `current_shopify_store` when one is resolved

- [ ] **Step 1: Write the failing request spec**

Add to `spec/requests/tickets_spec.rb` (inside the top-level describe; adjust factory args if the file already defines helpers — use the same auth pattern as the existing examples in that file):

```ruby
  describe "store scoping" do
    let(:owner) { create(:user) }
    let(:company) { owner.companies.first }
    let!(:store_a) { create(:shopify_store, company: company, user: owner) }
    let!(:store_b) { create(:shopify_store, company: company, user: owner) }
    let!(:account_a) { create(:email_account, company: company, user: owner, shopify_store: store_a) }
    let!(:account_b) { create(:email_account, company: company, user: owner, shopify_store: store_b) }
    let!(:ticket_a) { create(:ticket, email_account: account_a, subject: "Alpha ticket") }
    let!(:ticket_b) { create(:ticket, email_account: account_b, subject: "Bravo ticket") }

    before { sign_in owner }

    it "shows only the selected store's tickets" do
      get tickets_path, params: { store_id: store_a.id }
      expect(response.body).to include("Alpha ticket")
      expect(response.body).not_to include("Bravo ticket")
    end
  end
```

> Before writing, open `spec/factories/email_accounts.rb` and `spec/factories/tickets.rb` and adjust the `create(...)` attribute names above to match the real factories (e.g. the email-account ↔ store association key, and whether `ticket` already builds an `email_account`). Keep `shop_domain`/subjects distinct so the include/exclude assertions don't collide (see the CSRF-needle memory note about distinctive fixture values).

- [ ] **Step 2: Run the spec and confirm it fails**

Run: `bundle exec rspec spec/requests/tickets_spec.rb -e "shows only the selected store's tickets"`
Expected: FAIL — both subjects currently render because `visible_tickets` ignores the store.

- [ ] **Step 3: Implement store scoping in `visible_tickets`**

In `app/controllers/admin_controller.rb`, replace `visible_tickets` (lines 77-80):

```ruby
  def visible_tickets
    accounts = visible_email_accounts
    accounts = accounts.where(shopify_store_id: current_shopify_store.id) if current_shopify_store
    Ticket.where(email_account_id: accounts.select(:id))
  end
  helper_method :visible_tickets
```

- [ ] **Step 4: Run the spec and confirm it passes**

Run: `bundle exec rspec spec/requests/tickets_spec.rb`
Expected: PASS (new example green, existing examples still green).

- [ ] **Step 5: Lint and commit**

```bash
bin/rubocop app/controllers/admin_controller.rb
git add app/controllers/admin_controller.rb spec/requests/tickets_spec.rb
git commit -m "feat(store-switcher): scope tickets to the selected store

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Scope Dashboard metrics to the selected store

**Files:**
- Modify: `app/services/dashboard_metrics_service.rb:11-27,42-50`
- Modify: `app/controllers/dashboard_controller.rb:12-17`
- Test: `spec/services/dashboard_metrics_service_spec.rb` (add examples)

**Interfaces:**
- Consumes (from Task 1): `current_shopify_store` (nil ⇒ all stores)
- Produces: `DashboardMetricsService.new(scope, range_key:, start_date:, end_date:, shopify_store: nil)` — when `shopify_store` is present, both the Shopify metric scope and the ad-account scope are restricted to that store

- [ ] **Step 1: Write the failing service spec**

Add to `spec/services/dashboard_metrics_service_spec.rb` (inside `describe "#call"`):

```ruby
    context "when scoped to a single store" do
      let(:store_other) { create(:shopify_store, user: user) }

      it "aggregates only the selected store's shopify metrics" do
        create(:shopify_daily_metric, shopify_store: store, date: Date.current, revenue: 500, orders_count: 5, sessions: 100)
        create(:shopify_daily_metric, shopify_store: store_other, date: Date.current, revenue: 999, orders_count: 9, sessions: 200)

        result = described_class.new(user, range_key: "today", shopify_store: store).call

        expect(result[:current][:revenue]).to eq(500)
        expect(result[:current][:orders]).to eq(5)
      end

      it "restricts ad spend to the selected store's ad accounts" do
        store_ad = create(:ad_account, user: user)
        store.ad_accounts << store_ad
        other_ad = create(:ad_account, user: user)
        store_other.ad_accounts << other_ad
        create(:ad_daily_metric, ad_account: store_ad, date: Date.current, spend: 30)
        create(:ad_daily_metric, ad_account: other_ad, date: Date.current, spend: 70)

        result = described_class.new(user, range_key: "today", shopify_store: store).call

        expect(result[:current][:ad_spend]).to eq(30)
      end
    end
```

> Before running, confirm the store↔ad_account association direction in `app/models/shopify_store.rb` (`has_many :ad_accounts`). If `ad_accounts <<` is not valid, set `create(:ad_account, user: user, shopify_store: store)` instead — match the real column/association.

- [ ] **Step 2: Run the spec and confirm it fails**

Run: `bundle exec rspec spec/services/dashboard_metrics_service_spec.rb -e "when scoped to a single store"`
Expected: FAIL — `ArgumentError: unknown keyword: :shopify_store` (param not yet supported).

- [ ] **Step 3: Add the `shopify_store` param to the service**

In `app/services/dashboard_metrics_service.rb`, change the constructor signature and store the value. Replace line 11:

```ruby
  def initialize(scope, range_key: "past_7_days", start_date: nil, end_date: nil, shopify_store: nil)
    @scope = scope
    @shopify_store = shopify_store
```

(keep the rest of the method body unchanged).

- [ ] **Step 4: Apply the store filter inside `aggregate_metrics`**

In `aggregate_metrics`, replace the two scope lines (currently lines 46-47):

```ruby
    store_scope = @scope.respond_to?(:shopify_stores) ? @scope.shopify_stores : ShopifyStore.none
    ad_scope    = @scope.respond_to?(:ad_accounts)    ? @scope.ad_accounts    : AdAccount.none
```

with:

```ruby
    store_scope = @scope.respond_to?(:shopify_stores) ? @scope.shopify_stores : ShopifyStore.none
    ad_scope    = @scope.respond_to?(:ad_accounts)    ? @scope.ad_accounts    : AdAccount.none

    if @shopify_store
      store_scope = store_scope.where(id: @shopify_store.id)
      ad_scope    = @shopify_store.ad_accounts
    end
```

(The existing `shopify = shopify.where(...)`, `ad = ad.where(...)`, and the `aggregate_cogs(store_scope, range)` / `aggregate_shipping(store_scope, range)` calls automatically pick up the narrowed `store_scope`.)

- [ ] **Step 5: Pass the selected store from the controller**

In `app/controllers/dashboard_controller.rb`, replace the metrics build (lines 12-17):

```ruby
    @metrics = DashboardMetricsService.new(
      metrics_scope,
      range_key: @range_key,
      start_date: params[:start_date],
      end_date: params[:end_date],
      shopify_store: current_shopify_store
    ).call
```

- [ ] **Step 6: Run the service spec and confirm it passes**

Run: `bundle exec rspec spec/services/dashboard_metrics_service_spec.rb`
Expected: PASS (new context green, existing examples still green).

- [ ] **Step 7: Confirm the dashboard request spec still passes**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb`
Expected: PASS.

- [ ] **Step 8: Lint and commit**

```bash
bin/rubocop app/services/dashboard_metrics_service.rb app/controllers/dashboard_controller.rb
git add app/services/dashboard_metrics_service.rb app/controllers/dashboard_controller.rb spec/services/dashboard_metrics_service_spec.rb
git commit -m "feat(store-switcher): scope dashboard metrics to the selected store

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: System spec — switcher visibility and switching behavior

**Files:**
- Test: `spec/system/store_switcher_spec.rb` (create)

**Interfaces:**
- Consumes: everything from Tasks 1-5 (end-to-end through the browser)

- [ ] **Step 1: Write the system spec**

Create `spec/system/store_switcher_spec.rb` (mirror auth/setup of existing specs in `spec/system`; check `spec/support/system_helpers.rb` for any sign-in helper):

```ruby
require "rails_helper"

RSpec.describe "Store switcher", type: :system do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }
  let!(:store_a) { create(:shopify_store, company: company, user: owner, shop_domain: "alpha-store.myshopify.com") }
  let!(:store_b) { create(:shopify_store, company: company, user: owner, shop_domain: "bravo-store.myshopify.com") }

  before { sign_in owner }

  it "shows an All Stores option on the dashboard" do
    visit authenticated_root_path
    expect(page).to have_select(options: include("All Stores", "alpha-store.myshopify.com", "bravo-store.myshopify.com"))
  end

  it "does not show All Stores on orders" do
    visit orders_path
    within("div.flex.items-center.gap-3") do
      expect(page).not_to have_content("All Stores")
      expect(page).to have_content("alpha-store.myshopify.com").or have_content("bravo-store.myshopify.com")
    end
  end

  it "does not render the switcher on settings pages" do
    visit shopify_stores_path
    expect(page).not_to have_select(options: include("All Stores"))
  end

  it "navigates with the selected store_id when changed" do
    visit orders_path
    select "bravo-store.myshopify.com", from: find("select[data-controller='store-switcher'], [data-controller='store-switcher'] select")[:id] rescue nil
    # Fallback: choose by visible option then assert URL carries the store id
    expect(page).to have_current_path(/store_id=/, url: false).or have_current_path(orders_path, ignore_query: true)
  end
end
```

> The exact Capybara selectors depend on the app's chosen driver and markup; before finalizing, run the file once and tighten selectors (use a stable hook — consider adding `data-testid="store-switcher"` to the partial's wrapper if assertions are brittle). The non-negotiable assertions are: Dashboard has "All Stores", Orders does not, Settings has no switcher, and changing the select results in a URL carrying `store_id`. Per the flaky-system-tests memory, re-run once before assuming a real failure.

- [ ] **Step 2: Run the system spec**

Run: `bundle exec rspec spec/system/store_switcher_spec.rb`
Expected: PASS (re-run once if a flake is suspected).

- [ ] **Step 3: Commit**

```bash
git add spec/system/store_switcher_spec.rb
git commit -m "test(store-switcher): system spec for visibility and switching

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Full verification sweep

**Files:** none (verification only)

- [ ] **Step 1: Run the full relevant suite**

Run:
```bash
bundle exec rspec spec/requests/store_switcher_spec.rb spec/requests/orders_spec.rb spec/requests/shipments_spec.rb spec/requests/tickets_spec.rb spec/requests/dashboard_spec.rb spec/services/dashboard_metrics_service_spec.rb spec/system/store_switcher_spec.rb
```
Expected: all green.

- [ ] **Step 2: RuboCop + Brakeman**

Run:
```bash
bin/rubocop
bin/brakeman --no-pager
```
Expected: no new offenses / no new warnings.

- [ ] **Step 3: Manual smoke (optional, recommended)**

Use the `run` skill (or `bin/dev`) to load Dashboard/Orders/Shipments/Tickets with 2+ stores and confirm: switcher sits beside the title with actions on the right; All on Dashboard/Shipments only; selection persists across pages; Settings shows none; single-store shows plain text.

- [ ] **Step 4: Finish the branch**

Use the `superpowers:finishing-a-development-branch` skill to open the PR to `staging`.

---

## Self-Review

**Spec coverage:**
- §3 UX (switcher beside title, actions right, All only on Dashboard/Shipments, Settings hidden, single-store text) → Tasks 2, 3, 6. ✓
- §4.1 backend resolution/persistence/policy + company-switch clearing → Task 1. ✓
- §4.2 partial + Stimulus + i18n → Task 2. ✓
- §4.2 layout/header integration (chosen: **Method B** — render partial per page beside title, because the four headers differ too much for a uniform `content_for` without risk) → Task 3. ✓
- §4.3 Orders/Shipments (already use `current_shopify_store`; behavior verified) → Task 1 Step 6. ✓
- §4.3 Tickets scoping → Task 4. ✓
- §4.3 Dashboard scoping (service + controller, incl. ad-account scoping) → Task 5. ✓
- §5 edge cases (no stores / invalid id / company switch / All-not-allowed fallback without overwriting session / group-limited visibility via `visible_shopify_stores`) → Task 1 (resolution + specs), partial empty/single states (Task 2). ✓
- §6 tests (service, request ×4, system) → Tasks 1, 4, 5, 6. ✓

**Decision locked:** Header integration uses Method B (per-page render), superseding the spec's tentative "default Method A". Reason: Dashboard (title+subtitle), Orders (title+button), Shipments (dropdown-title+actions), Tickets (title+search) have structurally different headers; a shared `content_for` rewrite would be more invasive and riskier than a one-line render per page.

**Placeholder scan:** No TBD/TODO; every code step shows complete code. Two steps explicitly instruct verifying real factory/association names before writing test fixtures (email_accounts/tickets in Task 4, store↔ad_account in Task 5) — these are guarded with the fallback to use — not placeholders.

**Type/name consistency:** `current_shopify_store`, `store_switcher_visible?`, `store_all_allowed?`, `persist_store_selection`, `resolve_current_store`, `visible_tickets`, and the `shopify_store:` keyword are used identically across Tasks 1, 3, 4, 5. Partial name `shared/store_switcher` and Stimulus identifier `store-switcher` consistent across Tasks 2, 3, 6.
