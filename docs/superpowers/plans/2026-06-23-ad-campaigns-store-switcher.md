# Ad Campaigns Store Switcher Unification — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Ad Campaigns page use the shared store switcher in its title bar (session-shared `store_id` / `current_shopify_store`), removing its bespoke in-filter `shopify_store_id` selector, while keeping the ad-account sub-selector working.

**Architecture:** Add `ad_campaigns` to the store-switcher controllers (concrete-store only, no "All"). The controller reads `current_shopify_store` instead of `params[:shopify_store_id]`; the view renders `shared/store_switcher` beside the title and drops the old store `<select>`; the Stimulus filter controller loses its now-unused store handler. The ad-account sub-selector stays in the filter row, scoped to the selected store within the existing group/company view scope.

**Tech Stack:** Rails 8.1, Hotwire/Stimulus, Importmap, Tailwind, RSpec + FactoryBot, PostgreSQL (UUIDs).

## Global Constraints

- Never commit to `main`/`staging`; work on `feature/ad-campaigns-store-switcher` (already checked out).
- RSpec + FactoryBot only, no mocks, hit the real DB; keep 95%+ coverage.
- RuboCop Omakase; run `bin/rubocop` before each commit.
- Run Ruby tooling with `/home/simon/.rubies/ruby-3.4.7/bin` prepended to PATH. SimpleCov exit-2 on single-file runs is expected.
- System specs need the matched chromedriver: prepend `/tmp/chromedriver-linux64` to PATH.
- Ad Campaigns is concrete-store only: add it to `STORE_SWITCHER_CONTROLLERS` but NOT to `STORE_ALL_ALLOWED_CONTROLLERS`.
- Shared partial markup (from the prior feature): multi-store renders `<div data-controller="store-switcher" data-testid="store-switcher"><select data-action="change->store-switcher#switch">…`; single store renders `<span data-testid="store-switcher">shop_domain</span>` (no `data-controller`).

---

### Task 1: Ad Campaigns adopts the unified store switcher

**Files:**
- Modify: `app/controllers/admin_controller.rb` (`STORE_SWITCHER_CONTROLLERS` constant)
- Modify: `app/controllers/ad_campaigns_controller.rb:19-37` (store resolution in `index`)
- Modify: `app/views/ad_campaigns/index.html.erb` (title row + remove filter store block)
- Modify: `app/javascript/controllers/campaign_filter_controller.js` (drop store handler)
- Test: `spec/requests/ad_campaigns_spec.rb`

**Interfaces:**
- Consumes: `current_shopify_store` (concrete store for `ad_campaigns`), `store_switcher_visible?`, partial `shared/store_switcher` (all from the shipped store-switcher feature).
- Produces: Ad Campaigns store selection driven by `store_id` / session; `@selected_store = current_shopify_store`; no more `@show_store_selector` / `@shopify_stores` / `params[:shopify_store_id]`.

- [ ] **Step 1: Update the spec to the new behavior (failing)**

In `spec/requests/ad_campaigns_spec.rb`:

(a) Change the two `shopify_store_id` params to `store_id`:
- In "lists campaigns for the selected store": `get ad_campaigns_path, params: { store_id: store.id }`
- In "filters by ad account": `get ad_campaigns_path, params: { store_id: store.id, ad_account_id: account1.id }`

(b) Replace the two store-dropdown tests:

```ruby
    it "hides store dropdown when only one store" do
      create(:ad_campaign, ad_account: ad_account)
      sign_in user
      get ad_campaigns_path
      expect(response.body).not_to include("<select name=\"shopify_store_id\"")
    end

    it "shows store dropdown when multiple stores" do
      create(:shopify_store, user: user)
      create(:ad_campaign, ad_account: ad_account)
      sign_in user
      get ad_campaigns_path
      expect(response.body).to include("<select name=\"shopify_store_id\"")
    end
```

with:

```ruby
    it "shows the store name without a dropdown when only one store" do
      create(:ad_campaign, ad_account: ad_account)
      sign_in user
      get ad_campaigns_path
      expect(response.body).to include('data-testid="store-switcher"')
      expect(response.body).not_to include('data-controller="store-switcher"')
    end

    it "renders the unified store switcher in the title bar when multiple stores" do
      create(:shopify_store, user: user)
      create(:ad_campaign, ad_account: ad_account)
      sign_in user
      get ad_campaigns_path
      expect(response.body).to include('data-controller="store-switcher"')
      expect(response.body).not_to include("<select name=\"shopify_store_id\"")
    end
```

- [ ] **Step 2: Run the spec and confirm it fails**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/requests/ad_campaigns_spec.rb`
Expected: FAIL — "renders the unified store switcher…" fails (no `data-controller="store-switcher"` yet; old `shopify_store_id` select still present).

- [ ] **Step 3: Add `ad_campaigns` to the switcher controllers**

In `app/controllers/admin_controller.rb`, change:

```ruby
  STORE_SWITCHER_CONTROLLERS = %w[dashboard orders shipments tickets].freeze
```

to:

```ruby
  STORE_SWITCHER_CONTROLLERS = %w[dashboard orders shipments tickets ad_campaigns].freeze
```

(Leave `STORE_ALL_ALLOWED_CONTROLLERS` unchanged — Ad Campaigns stays concrete-store only.)

- [ ] **Step 4: Switch the controller to `current_shopify_store`**

In `app/controllers/ad_campaigns_controller.rb`, replace the store-resolution block in `index` (the lines from `view_scope = selected_view_group || current_company` through the `@ad_accounts = …` assignment) with:

```ruby
    view_scope = selected_view_group || current_company
    base_ad_accounts = view_scope.respond_to?(:ad_accounts) ? view_scope.ad_accounts : visible_ad_accounts

    @selected_store = current_shopify_store

    @ad_accounts = if @selected_store
      base_ad_accounts.where(shopify_store: @selected_store).order(:account_name)
    else
      base_ad_accounts.order(:account_name)
    end

    @selected_account = if params[:ad_account_id].present? && params[:ad_account_id] != "all"
      @ad_accounts.find_by(id: params[:ad_account_id])
    end
```

This removes `@shopify_stores`, `@show_store_selector`, and the `params[:shopify_store_id]` lookup. (Keep everything after `@selected_account` — the `accounts = …`, date parsing, campaign query, etc. — unchanged.)

> Note: the `@selected_account` assignment already existed right after the old `@ad_accounts` block; the snippet above reproduces it so the block stays contiguous. Verify you have not duplicated it — there must be exactly one `@selected_account =` in `index`.

- [ ] **Step 5: Render the switcher in the title; remove the old filter store block**

In `app/views/ad_campaigns/index.html.erb`:

(a) Replace:

```erb
  <h1 class="text-2xl font-bold text-gray-900"><%= t("ad_campaigns.title") %></h1>

  <%= render "shared/group_view_switcher" %>
```

with:

```erb
  <div class="flex items-center gap-3">
    <h1 class="text-2xl font-bold text-gray-900"><%= t("ad_campaigns.title") %></h1>
    <%= render "shared/store_switcher" %>
  </div>

  <%= render "shared/group_view_switcher" %>
```

(b) Delete the entire store-selector block in the filter row — from the `<%# Store selector (only if multiple stores) %>` comment through the matching `<% end %>` of its `<% if @show_store_selector %> … <% else %> … <% end %>` (the block that renders `<select name="shopify_store_id">` and the single-store hidden input). Leave the `<%# Ad Account filter … %>` block and everything after it intact.

- [ ] **Step 6: Remove the now-unused store handler from the Stimulus controller**

In `app/javascript/controllers/campaign_filter_controller.js`:

(a) Remove `"storeSelect"` from the `static targets = [...]` array (it becomes:
`static targets = ["fromDate", "toDate", "rangeButton", "filterForm", "statusFilter", "sortColumn", "sortDirection", "statusSelect"]`).

(b) Delete the method:

```javascript
  storeChanged() {
    this.filterFormTarget.requestSubmit()
  }
```

- [ ] **Step 7: Run the spec and confirm it passes**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/requests/ad_campaigns_spec.rb`
Expected: PASS (all examples, including the two rewritten ones).

- [ ] **Step 8: Run related specs that touch this controller/area**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/requests/ad_campaigns_spec.rb spec/requests/group_view_switcher_spec.rb spec/requests/store_switcher_spec.rb spec/requests/data_isolation_spec.rb`
Expected: PASS. (Store switcher resolution for `ad_campaigns` now persists `store_id`; group_view_switcher behavior unchanged.)

- [ ] **Step 9: Lint and commit**

```bash
PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bin/rubocop app/controllers/admin_controller.rb app/controllers/ad_campaigns_controller.rb spec/requests/ad_campaigns_spec.rb
git add app/controllers/admin_controller.rb app/controllers/ad_campaigns_controller.rb app/views/ad_campaigns/index.html.erb app/javascript/controllers/campaign_filter_controller.js spec/requests/ad_campaigns_spec.rb
git commit -m "feat(store-switcher): unify ad campaigns store selection into the title bar

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Full verification sweep + PR

**Files:** none (verification only)

- [ ] **Step 1: Full non-system suite**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec --exclude-pattern "spec/system/**/*_spec.rb"`
Expected: 0 failures, coverage ≥ 95%.

- [ ] **Step 2: System specs (matched chromedriver)**

Run: `PATH=/tmp/chromedriver-linux64:/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/system/store_switcher_spec.rb`
Expected: PASS (re-run once if a flake is suspected, per project memory).

- [ ] **Step 3: RuboCop + Brakeman + bundler-audit**

Run:
```bash
export PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
```
Expected: 0 offenses / 0 warnings / no vulnerabilities.

- [ ] **Step 4: Push and open PR to staging**

```bash
git push -u origin feature/ad-campaigns-store-switcher
gh pr create --base staging --head feature/ad-campaigns-store-switcher --title "feat: unify ad campaigns store switcher into the title bar" --body "<summary>"
```

- [ ] **Step 5: Codex second-opinion review + CI green, then merge**

Generate the branch diff and run a Codex review; confirm CI is green on the PR; address findings; merge to staging.

---

## Self-Review

**Spec coverage:**
- §3.1 AdminController constant → Task 1 Step 3. ✓
- §3.2 controller uses `current_shopify_store`, ad-account scoping preserved → Task 1 Step 4. ✓
- §3.3 title-bar switcher + remove filter store block → Task 1 Step 5. ✓
- §3.4 JS cleanup → Task 1 Step 6. ✓
- §3.5 param preservation / ad_account fallback → handled by existing `@selected_account` nil→all logic (kept in Step 4). ✓
- §5 tests (store_id rename, switcher render single/multi, group/isolation regress) → Task 1 Steps 1, 8; Task 2. ✓

**Placeholder scan:** Step 5(b) describes a delete by its exact ERB comment markers and `if @show_store_selector` boundary rather than line numbers (the block is unambiguous in the file); PR body `<summary>` in Task 2 Step 4 is filled at PR time. No code-step placeholders.

**Type/name consistency:** `current_shopify_store`, `@selected_store`, `@ad_accounts`, `@selected_account`, `STORE_SWITCHER_CONTROLLERS`, partial `shared/store_switcher`, Stimulus id `store-switcher` all match the shipped feature and across steps.
