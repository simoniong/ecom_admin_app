# Order Packing Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Phase 1 of the order-packing project — per-SKU customs declaration info (with a dedicated management page) and Raydo logistics-channel management.

**Architecture:** Module 1 adds customs columns to `product_variants`, a new `products` permission, converts the Products sidebar entry into a nav-group (商品成本 + 報關信息), and a customs page mirroring the existing cost page. Module 2 adds `logistics_accounts` + `logistics_channels` (company-scoped, encrypted creds), a `RaydoService` HTTParty client (auth + product list), and a channel-management UI under Shipping whose create flow picks a Raydo `product_id` from a live dropdown.

**Tech Stack:** Rails 8.1, PostgreSQL UUID PKs, Hotwire/Turbo, Tailwind, HTTParty, RSpec + FactoryBot, WebMock (external HTTP boundary).

## Global Constraints

- All table IDs use UUIDs.
- RSpec + FactoryBot, no fixtures; ≥95% line coverage. The only mocking allowed is the external HTTP boundary (Raydo) via WebMock (`webmock ~> 3.23` is in the Gemfile).
- Turbo-driven UI ships a system spec in the same commit.
- Permissions are boolean strings in `memberships.permissions` (jsonb array); new keys go in `Membership::AVAILABLE_PERMISSIONS` and get an i18n label under `invitations.permission_labels.<key>`. `has_permission?` returns true for owners regardless.
- Credentials (Raydo password) stored with `encrypts` (non-deterministic), per the repo convention (`shopify_store.rb`, `email_account.rb`).
- i18n keys in all three locales: `config/locales/en.yml`, `config/locales/zh-TW.yml`, `config/locales/zh-CN.yml`.
- Route helpers take keyword ids under the `scope "(:locale)"` wrapper (e.g. `shopify_store_path(id: ...)`).
- Never commit to `main`/`staging`; work on `feature/order-packing-phase1` (already off `origin/staging`).
- Full PRD: `.plan/PRD_order_packing.md`. Raydo API reference: `.plan/raydo_api_notes.md`. Phase-1 design: `docs/superpowers/specs/2026-07-19-order-packing-phase1-design.md`.

## File Structure

**Module 1 — customs**
- `db/migrate/*_add_customs_fields_to_product_variants.rb`
- `app/models/product_variant.rb` — customs fields, `customs_complete?`, context validation
- `app/models/membership.rb` — add `products` to AVAILABLE_PERMISSIONS
- `app/controllers/admin_controller.rb` — PERMISSION_KEY_MAP remap products→products
- `app/controllers/product_customs_controller.rb` — new 報關 index page
- `app/controllers/product_variants_controller.rb` — customs update + bulk_update_customs
- `app/views/product_customs/index.html.erb` (+ row partial) — mirror products/index
- `app/views/shared/_sidebar.html.erb` — Products → nav-group
- `config/routes.rb`, `config/locales/*.yml`

**Module 2 — logistics channels**
- `db/migrate/*_create_logistics_accounts.rb`, `*_create_logistics_channels.rb`
- `app/models/logistics_account.rb`, `app/models/logistics_channel.rb`
- `app/services/raydo_service.rb`
- `app/controllers/logistics_accounts_controller.rb`, `app/controllers/logistics_channels_controller.rb`
- `app/views/logistics_accounts/*`, `app/views/logistics_channels/*`
- `app/models/membership.rb`, `app/controllers/admin_controller.rb`, `_sidebar.html.erb`, `config/routes.rb`, `config/locales/*.yml`

---

# Module 1 — Product customs info

### Task 1: Customs columns + model validation

**Files:**
- Create: `db/migrate/20260719130001_add_customs_fields_to_product_variants.rb`
- Modify: `app/models/product_variant.rb`
- Test: `spec/models/product_variant_spec.rb`

**Interfaces:**
- Produces: `ProductVariant#customs_name_zh/customs_name_en/declared_value_usd/hs_code/import_hs_code`, `ProductVariant#customs_complete?`, and a `:customs` validation context. Consumed by Task 3 (customs page writes) and later Phase 2.

- [ ] **Step 1: Migration**
```ruby
class AddCustomsFieldsToProductVariants < ActiveRecord::Migration[8.1]
  def change
    # Per-SKU customs declaration. Declared weight reuses the existing
    # weight_grams column (shared with shipping-cost calc), not a new field.
    add_column :product_variants, :customs_name_zh, :string
    add_column :product_variants, :customs_name_en, :string
    add_column :product_variants, :declared_value_usd, :decimal, precision: 10, scale: 2
    add_column :product_variants, :hs_code, :string
    add_column :product_variants, :import_hs_code, :string
  end
end
```
Run: `bin/rails db:migrate && bin/rails db:test:prepare`.

- [ ] **Step 2: Failing model spec**

Add to `spec/models/product_variant_spec.rb`:
```ruby
describe "customs info" do
  it "is complete only when zh name, en name, declared value and weight are all present" do
    v = build(:product_variant, customs_name_zh: "積木", customs_name_en: "Blocks",
              declared_value_usd: 5, weight_grams: 100)
    expect(v.customs_complete?).to be(true)
  end

  it "is incomplete when any required customs field is blank" do
    v = build(:product_variant, customs_name_zh: "積木", customs_name_en: "Blocks",
              declared_value_usd: nil, weight_grams: 100)
    expect(v.customs_complete?).to be(false)
  end

  it "on the :customs context, requires all four fields together" do
    v = build(:product_variant, customs_name_zh: "積木", customs_name_en: nil,
              declared_value_usd: 5, weight_grams: 100)
    expect(v.valid?(:customs)).to be(false)
    expect(v.errors[:customs_name_en]).to be_present
  end

  it "on the default context, does NOT require customs fields (Shopify sync creates blanks)" do
    v = build(:product_variant, customs_name_zh: nil, customs_name_en: nil, declared_value_usd: nil)
    v.valid?
    expect(v.errors[:customs_name_en]).to be_empty
  end
end
```

- [ ] **Step 3: Run — expect failure** (`customs_complete?` undefined).
Run: `bundle exec rspec spec/models/product_variant_spec.rb -e "customs info"` → FAIL.

- [ ] **Step 4: Implement in `app/models/product_variant.rb`**

Add after the existing validations:
```ruby
  CUSTOMS_REQUIRED = %i[customs_name_zh customs_name_en declared_value_usd weight_grams].freeze

  validates :customs_name_zh, :customs_name_en, presence: true, on: :customs
  validates :declared_value_usd, presence: true, numericality: { greater_than: 0 }, on: :customs
  validates :weight_grams, presence: true, on: :customs

  def customs_complete?
    customs_name_zh.present? && customs_name_en.present? &&
      declared_value_usd.present? && weight_grams.present?
  end
```
(`weight_grams`'s existing default-context validation stays `numericality: { greater_than: 0, allow_nil: true }`.)

- [ ] **Step 5: Run — expect pass.** `bundle exec rspec spec/models/product_variant_spec.rb -e "customs info"` → PASS.

- [ ] **Step 6: Commit**
```bash
bin/rubocop app/models/product_variant.rb
git add db/migrate app/models/product_variant.rb db/schema.rb spec/models/product_variant_spec.rb
git commit -m "feat(products): add per-SKU customs fields and :customs validation context"
```

---

### Task 2: `products` permission + Products nav-group

**Files:**
- Modify: `app/models/membership.rb` (AVAILABLE_PERMISSIONS)
- Modify: `app/controllers/admin_controller.rb` (PERMISSION_KEY_MAP)
- Modify: `app/views/shared/_sidebar.html.erb` (Products → nav-group)
- Modify: `config/locales/*.yml`
- Test: `spec/requests/sidebar_navigation_spec.rb`, `spec/requests/products_spec.rb`

**Interfaces:**
- Consumes: nothing new. Produces: `products` permission gating the Products group; `#products-menu` nav-group. Task 3's customs page hangs under this group.

- [ ] **Step 1: Add the permission**

`app/models/membership.rb` — add `products` to the array:
```ruby
  AVAILABLE_PERMISSIONS = %w[
    orders shipments tickets ad_campaigns
    shopify_stores ad_accounts email_accounts
    shipping_reminder_rules parcels products
  ].freeze
```

- [ ] **Step 2: Remap PERMISSION_KEY_MAP**

`app/controllers/admin_controller.rb` — change the `products`/`product_variants` mappings from `"shopify_stores"` to `"products"`, and add the new customs controller:
```ruby
    "products" => "products",
    "product_variants" => "products",
    "product_customs" => "products",
```
(Replace the existing two `... => "shopify_stores"` lines for products/product_variants.)

- [ ] **Step 3: i18n — permission label + nav labels (all three locales)**

`en.yml`: under `invitations.permission_labels:` add `products: "Products"`. Under `nav:` add `product_costs: "Product Costs"` and `product_customs: "Customs Info"`.
`zh-TW.yml`: `products: "商品"`; `product_costs: "商品成本"`; `product_customs: "報關信息"`.
`zh-CN.yml`: `products: "商品"`; `product_costs: "商品成本"`; `product_customs: "报关信息"`.
(`nav.products` already exists = the group header label "Products/商品/商品".)

- [ ] **Step 4: Convert the Products sidebar link to a nav-group**

In `app/views/shared/_sidebar.html.erb`, replace the existing single Products `link_to` block (the `<% if current_membership&.has_permission?("shopify_stores") %> ... products_path ... %>` block that currently sits below the Shipping group) with a nav-group mirroring the Shipping/Settings pattern:
```erb
    <%# Products group — cost editor + customs info %>
    <% if current_membership&.has_permission?("products") %>
      <% products_active = %w[products product_variants product_customs].include?(controller_name) %>
      <div data-controller="nav-group" data-nav-group-open-value="<%= products_active %>">
        <button type="button" data-action="click->nav-group#toggle"
                aria-expanded="<%= products_active %>" aria-controls="products-menu"
                class="w-full flex items-center gap-3 px-3 py-2 text-sm font-medium rounded-md <%= products_active ? 'text-gray-900' : 'text-gray-600 hover:bg-gray-50 hover:text-gray-900' %>">
          <svg class="w-5 h-5" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" d="M9.568 3H5.25A2.25 2.25 0 0 0 3 5.25v4.318c0 .597.237 1.17.659 1.591l9.581 9.581c.699.699 1.78.872 2.607.33a18.095 18.095 0 0 0 5.223-5.223c.542-.827.369-1.908-.33-2.607L11.16 3.66A2.25 2.25 0 0 0 9.568 3Z" />
            <path stroke-linecap="round" stroke-linejoin="round" d="M6 6h.008v.008H6V6Z" />
          </svg>
          <%= t("nav.products") %>
          <svg data-nav-group-target="arrow" class="w-4 h-4 ml-auto transition-transform duration-200 <%= products_active ? 'rotate-90' : '' %>" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" d="m8.25 4.5 7.5 7.5-7.5 7.5" />
          </svg>
        </button>
        <div id="products-menu" data-nav-group-target="menu" class="ml-4 mt-1 space-y-1 <%= products_active ? '' : 'hidden' %>">
          <%= link_to products_path, data: { action: "click->sidebar#close" },
              class: "flex items-center gap-3 px-3 py-2 text-sm font-medium rounded-md #{controller_name == 'products' ? 'bg-gray-100 text-gray-900' : 'text-gray-600 hover:bg-gray-50 hover:text-gray-900'}" do %>
            <svg class="w-4 h-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M2.25 18.75a60.07 60.07 0 0 1 15.797 2.101c.727.198 1.453-.342 1.453-1.096V18.75M3.75 4.5v.75A.75.75 0 0 1 3 6h-.75m0 0v-.375c0-.621.504-1.125 1.125-1.125H20.25M2.25 6v9m18-10.5v.75c0 .414.336.75.75.75h.75m-1.5-1.5h.375c.621 0 1.125.504 1.125 1.125v9.75c0 .621-.504 1.125-1.125 1.125h-.375m1.5-1.5H21a.75.75 0 0 0-.75.75v.75m0 0H3.75m0 0h-.375a1.125 1.125 0 0 1-1.125-1.125V15m1.5 1.5v-.75A.75.75 0 0 0 3 15h-.75M15 10.5a3 3 0 1 1-6 0 3 3 0 0 1 6 0Zm3 0h.008v.008H18V10.5Zm-12 0h.008v.008H6V10.5Z" /></svg>
            <%= t("nav.product_costs") %>
          <% end %>
          <%= link_to product_customs_path, data: { action: "click->sidebar#close" },
              class: "flex items-center gap-3 px-3 py-2 text-sm font-medium rounded-md #{controller_name == 'product_customs' ? 'bg-gray-100 text-gray-900' : 'text-gray-600 hover:bg-gray-50 hover:text-gray-900'}" do %>
            <svg class="w-4 h-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M9 12h3.75M9 15h3.75M9 18h3.75m3 .75H18a2.25 2.25 0 0 0 2.25-2.25V6.108c0-1.135-.845-2.098-1.976-2.192a48.424 48.424 0 0 0-1.123-.08m-5.801 0c-.065.21-.1.433-.1.664 0 .414.336.75.75.75h4.5a.75.75 0 0 0 .75-.75 2.25 2.25 0 0 0-.1-.664m-5.8 0A2.251 2.251 0 0 1 13.5 2.25H15c1.012 0 1.867.668 2.15 1.586m-5.8 0c-.376.023-.75.05-1.124.08C9.095 4.01 8.25 4.973 8.25 6.108V8.25m0 0H4.875c-.621 0-1.125.504-1.125 1.125v11.25c0 .621.504 1.125 1.125 1.125h9.75c.621 0 1.125-.504 1.125-1.125V9.375c0-.621-.504-1.125-1.125-1.125H8.25Z" /></svg>
            <%= t("nav.product_customs") %>
          <% end %>
        </div>
      </div>
    <% end %>
```
(`product_customs_path` is defined in Task 3; if implementing tasks strictly in order, add the route in Task 3 before running the sidebar system spec, or add the route line here.)

- [ ] **Step 5: Request specs — permission gate + nav group**

In `spec/requests/products_spec.rb`, add:
```ruby
describe "products permission gate" do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }

  it "allows a member granted the products permission" do
    m = create(:user); create(:membership, user: m, company: company, role: :member, permissions: ["products"])
    sign_in m; patch switch_company_path(id: company.id)
    get products_path
    expect(response).to have_http_status(:ok)
  end

  it "denies a member without the products permission (redirect)" do
    m = create(:user); create(:membership, user: m, company: company, role: :member, permissions: ["shopify_stores"])
    sign_in m; patch switch_company_path(id: company.id)
    get products_path
    expect(response).to redirect_to(authenticated_root_path)
  end
end
```
In `spec/requests/sidebar_navigation_spec.rb` add a "Products group" describe asserting `doc.at_css("#products-menu")` present for the owner and contains `products_path` and `product_customs_path`; hidden for a member with neither permission.

- [ ] **Step 6: System spec** (Turbo nav-group + gating) in `spec/system/` — owner sees the Products group; clicking expands to reveal 商品成本 + 報關信息.

- [ ] **Step 7: Run + commit**
```bash
bundle exec rspec spec/requests/products_spec.rb spec/requests/sidebar_navigation_spec.rb
bin/rubocop app/models/membership.rb app/controllers/admin_controller.rb
git add app/models/membership.rb app/controllers/admin_controller.rb app/views/shared/_sidebar.html.erb config/locales spec
git commit -m "feat(products): dedicated products permission and Products nav-group"
```

---

### Task 3: 報關信息 page + customs writes (enforce required-together)

**Files:**
- Create: `app/controllers/product_customs_controller.rb`
- Create: `app/views/product_customs/index.html.erb`, `app/views/product_customs/_row.html.erb`
- Modify: `app/controllers/product_variants_controller.rb` (customs single-update + `bulk_update_customs`)
- Modify: `config/routes.rb`
- Modify: `config/locales/*.yml`
- Test: `spec/requests/product_variants_spec.rb`, `spec/system/product_customs_spec.rb`

**Interfaces:**
- Consumes: Task 1 (`:customs` context, `customs_complete?`), Task 2 (`products` permission, nav-group).
- Produces: `product_customs_path` (index), a customs single-update path, and `bulk_update_customs_product_variants_path`.

- [ ] **Step 1: Routes**
```ruby
    resource :product_customs, only: [ :show ], controller: "product_customs", path: "product_customs" do
    end
```
Simpler: use `get "product_customs" => "product_customs#index", as: :product_customs`. And extend product_variants:
```ruby
    resources :product_variants, only: [ :update ] do
      collection do
        post :bulk_update
        post :bulk_update_customs
        get :matching_ids
      end
    end
    get "product_customs" => "product_customs#index", as: :product_customs
```

- [ ] **Step 2: Controller** `app/controllers/product_customs_controller.rb` — mirror `ProductsController#index` (same store scoping, search, pagination) but render the customs view:
```ruby
class ProductCustomsController < AdminController
  PER_PAGE_DEFAULT = 50
  PER_PAGE_OPTIONS = [ 25, 50, 100, 200, 300, 500 ].freeze

  def index
    @search = params[:search].presence
    @only_incomplete = params[:incomplete].present?
    @page = [ params[:page].to_i, 1 ].max
    per_page = Integer(params[:per_page], exception: false)
    @per_page = PER_PAGE_OPTIONS.include?(per_page) ? per_page : PER_PAGE_DEFAULT

    @shopify_store = current_shopify_store || visible_shopify_stores.first
    return redirect_to(shopify_stores_path, alert: t("products.no_store")) unless @shopify_store

    variants = filtered_variants
    @total_count = variants.count
    @total_pages = (@total_count.to_f / @per_page).ceil
    @page = [ @page, @total_pages ].min if @total_pages > 0
    @variants = variants.order("products.title ASC, product_variants.title ASC")
                        .offset((@page - 1) * @per_page).limit(@per_page)
  end

  private

  def filtered_variants
    scope = ProductVariant.joins(:product)
                          .where(products: { shopify_store_id: @shopify_store.id })
                          .includes(:product)
    if @search
      q = "%#{ActiveRecord::Base.sanitize_sql_like(@search)}%"
      scope = scope.where("product_variants.sku ILIKE :q OR product_variants.title ILIKE :q OR products.title ILIKE :q", q: q)
    end
    if @only_incomplete
      scope = scope.where("customs_name_zh IS NULL OR customs_name_zh = '' OR customs_name_en IS NULL OR customs_name_en = '' OR declared_value_usd IS NULL OR weight_grams IS NULL")
    end
    scope
  end
end
```

- [ ] **Step 3: View** `app/views/product_customs/index.html.erb` + `_row.html.erb` — read `app/views/products/index.html.erb` and `app/views/product_variants/_row.html.erb` and mirror them, replacing the cost columns (unit_cost/packaging_cost/weight) with the customs columns: 中文名 / 英文名 / 申報金額USD / 海關編碼 / 進口海關編碼 / 重量(g) + a 完成/未完成 badge. Keep the search box + store selector + pagination. Add an "只顯示未完成" checkbox that adds `?incomplete=1`. Provide a bulk-edit form posting to `bulk_update_customs_product_variants_path` with the customs fields. Single-row inline edit posts to `product_variant_path(id: variant)` (PATCH) with `product_variant[customs_*]`.

- [ ] **Step 4: Extend `ProductVariantsController`** — customs single-update must validate on the `:customs` context (enforce required-together), and add `bulk_update_customs`:
```ruby
  # in update: when customs params are present, validate on :customs context.
  def update
    @variant.assign_attributes(variant_params)
    context = customs_touched? ? :customs : nil
    if @variant.save(context: context)
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to product_customs_path, notice: t("product_variants.updated") }
      end
    else
      respond_to do |format|
        format.turbo_stream { render :update, status: :unprocessable_entity }
        format.html { redirect_back fallback_location: product_customs_path, alert: @variant.errors.full_messages.join(", ") }
      end
    end
  end

  def bulk_update_customs
    ids = Array(params[:variant_ids]).map(&:to_s)
    return redirect_to(product_customs_path, alert: t("product_variants.bulk_no_selection")) if ids.empty?
    updates = {}
    %i[customs_name_zh customs_name_en declared_value_usd hs_code import_hs_code weight_grams].each do |f|
      updates[f] = params[f] if params[f].to_s.strip.present?
    end
    return redirect_to(product_customs_path, alert: t("product_variants.bulk_no_fields")) if updates.empty?
    count = 0
    ProductVariant.transaction do
      scoped_variants.where(id: ids).find_each do |v|
        v.assign_attributes(updates)
        v.save!(context: :customs)  # enforce required-together on customs edits
        count += 1
      end
    end
    redirect_to product_customs_path(request.query_parameters.slice(:store_id, :search, :per_page, :page, :incomplete)),
                notice: t("product_variants.bulk_updated", count: count)
  rescue ActiveRecord::RecordInvalid => e
    redirect_to product_customs_path, alert: e.record.errors.full_messages.join(", ")
  end
```
Add a private `customs_touched?` returning true if any `product_variant[customs_*]`/`declared_value_usd` key is present, and extend `variant_params` to also permit `:customs_name_zh, :customs_name_en, :declared_value_usd, :hs_code, :import_hs_code`. **Important:** the existing cost `bulk_update` and `variant_params` for the cost page must NOT start enforcing the `:customs` context — cost edits stay on the default context. Keep cost `bulk_update` unchanged; only `bulk_update_customs` uses `context: :customs`.

- [ ] **Step 5: Request specs** `spec/requests/product_variants_spec.rb`:
  - customs bulk update with all required present → succeeds, values saved.
  - customs bulk update with a required field blank on a selected variant → **rejected** (RecordInvalid), values NOT saved (enforce-required).
  - cost `bulk_update` still works with only `unit_cost` (does NOT trigger customs validation) — regression guard.
  - permission: member with `products` can POST customs bulk; member without is redirected.

- [ ] **Step 6: System spec** `spec/system/product_customs_spec.rb`: visit the customs page, inline-edit a SKU's customs, saving with a blank required field shows the error; the 未完成 filter narrows the list. (`:js`, Turbo.)

- [ ] **Step 7: Run + commit**
```bash
bundle exec rspec spec/requests/product_variants_spec.rb spec/system/product_customs_spec.rb
bin/rubocop app/controllers/product_customs_controller.rb app/controllers/product_variants_controller.rb
git add app/controllers config/routes.rb app/views/product_customs config/locales spec
git commit -m "feat(products): customs info page with enforced-required editing and bulk update"
```

---

# Module 2 — Logistics channel management

### Task 4: logistics_accounts + logistics_channels models

**Files:**
- Create: `db/migrate/20260719140001_create_logistics_accounts.rb`, `db/migrate/20260719140002_create_logistics_channels.rb`
- Create: `app/models/logistics_account.rb`, `app/models/logistics_channel.rb`
- Create: `spec/factories/logistics_accounts.rb`, `spec/factories/logistics_channels.rb`
- Test: `spec/models/logistics_account_spec.rb`, `spec/models/logistics_channel_spec.rb`

**Interfaces:**
- Produces: `LogisticsAccount` (company-scoped, provider, encrypted password, cached customer_id/customer_userid, url1_base/url2_base) with `has_many :logistics_channels`; `LogisticsChannel` (belongs_to account, name, product_id, product_shortname, shopify_carrier_name default "Other", tracking_url_template default 17track). Consumed by Tasks 5 (RaydoService) and 6 (UI).

- [ ] **Step 1: Migrations**
```ruby
class CreateLogisticsAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :logistics_accounts, id: :uuid do |t|
      t.references :company, type: :uuid, null: false, foreign_key: true
      t.string :provider, null: false, default: "raydo"
      t.string :username
      t.text   :password           # encrypted at the model layer
      t.string :customer_id         # cached from selectAuth
      t.string :customer_userid     # cached from selectAuth
      t.string :url1_base           # orders/query API base
      t.string :url2_base           # label-printing API base
      t.timestamps
    end
    add_index :logistics_accounts, [ :company_id, :provider ], unique: true
  end
end
```
```ruby
class CreateLogisticsChannels < ActiveRecord::Migration[8.1]
  def change
    create_table :logistics_channels, id: :uuid do |t|
      t.references :logistics_account, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false                 # 別稱, shown in packing module
      t.string :product_id, null: false           # Raydo 運輸方式ID
      t.string :product_shortname                 # Raydo short name, reference
      t.string :shopify_carrier_name, null: false, default: "Other"
      t.string :tracking_url_template, null: false, default: "https://t.17track.net/en#nums=#TrackingNumber#"
      t.timestamps
    end
  end
end
```
Run `bin/rails db:migrate && bin/rails db:test:prepare`.

- [ ] **Step 2: Models + factories** (write failing specs first for the validations/associations below, run red, then implement).

`app/models/logistics_account.rb`:
```ruby
class LogisticsAccount < ApplicationRecord
  belongs_to :company
  has_many :logistics_channels, dependent: :destroy

  encrypts :password, deterministic: false

  PROVIDERS = %w[raydo].freeze
  validates :provider, presence: true, inclusion: { in: PROVIDERS }
  validates :provider, uniqueness: { scope: :company_id }
end
```
`app/models/logistics_channel.rb`:
```ruby
class LogisticsChannel < ApplicationRecord
  belongs_to :logistics_account
  has_one :company, through: :logistics_account

  validates :name, presence: true
  validates :product_id, presence: true
  validates :shopify_carrier_name, presence: true
  validates :tracking_url_template, presence: true
end
```
Factories:
```ruby
# spec/factories/logistics_accounts.rb
FactoryBot.define do
  factory :logistics_account do
    company
    provider { "raydo" }
    username { "TEST" }
    password { "123456" }
    url1_base { "http://www.sz56t.com:8082" }
    url2_base { "http://www.sz56t.com:8089" }
  end
end
# spec/factories/logistics_channels.rb
FactoryBot.define do
  factory :logistics_channel do
    logistics_account
    sequence(:name) { |n| "Channel #{n}" }
    sequence(:product_id) { |n| "PID#{n}" }
    shopify_carrier_name { "Other" }
    tracking_url_template { "https://t.17track.net/en#nums=#TrackingNumber#" }
  end
end
```

- [ ] **Step 3: Model specs** cover: password is encrypted (`account.reload.password == "123456"` but the raw DB column differs — assert via `LogisticsAccount.connection.select_value` that the stored value ≠ plaintext, mirroring existing encrypts specs if any; otherwise assert round-trip + that the ciphertext column isn't the plaintext); provider inclusion; provider uniqueness scoped to company; channel presence validations; default `shopify_carrier_name`/`tracking_url_template`.

- [ ] **Step 4: Run + commit**
```bash
bundle exec rspec spec/models/logistics_account_spec.rb spec/models/logistics_channel_spec.rb
bin/rubocop app/models/logistics_account.rb app/models/logistics_channel.rb
git add db/migrate app/models/logistics_*.rb spec/factories/logistics_* db/schema.rb spec/models/logistics_*
git commit -m "feat(logistics): logistics_accounts + logistics_channels models"
```

---

### Task 5: RaydoService + `logistics_channels` permission

**Files:**
- Create: `app/services/raydo_service.rb`
- Modify: `app/models/membership.rb`, `app/controllers/admin_controller.rb`
- Test: `spec/services/raydo_service_spec.rb`

**Interfaces:**
- Consumes: `LogisticsAccount` (Task 4). Produces: `RaydoService.new(account)#authenticate` → `{ "customer_id" =>, "customer_userid" =>, "ack" => }`; `#product_list` → `[{ "product_id" =>, "product_shortname" => }, ...]`. Consumed by Task 6.

- [ ] **Step 1: Service** `app/services/raydo_service.rb` (HTTParty, mirror `shopify_service.rb`):
```ruby
class RaydoService
  class Error < StandardError; end

  def initialize(account)
    @account = account
  end

  # GET url1/selectAuth.htm?username=&password= -> {customer_id, customer_userid, ack}
  def authenticate
    res = get("/selectAuth.htm", username: @account.username, password: @account.password)
    raise Error, "Raydo auth failed" unless res.is_a?(Hash) && res["ack"].to_s == "true"
    res
  end

  # GET url1/getProductList.htm -> [{product_id, product_shortname}, ...]
  def product_list
    res = get("/getProductList.htm")
    raise Error, "Unexpected product list response" unless res.is_a?(Array)
    res
  end

  private

  def get(path, query = {})
    base = @account.url1_base.to_s.chomp("/")
    resp = HTTParty.get("#{base}#{path}", query: query, timeout: 20)
    raise Error, "Raydo HTTP #{resp.code}" unless resp.success?
    resp.parsed_response
  end
end
```

- [ ] **Step 2: Permission** — add `logistics_channels` to `AVAILABLE_PERMISSIONS`; map `logistics_channels` and `logistics_accounts` controllers to `"logistics_channels"` in `PERMISSION_KEY_MAP`.

- [ ] **Step 3: Service spec** `spec/services/raydo_service_spec.rb` — stub the HTTP boundary with WebMock:
```ruby
require "rails_helper"
RSpec.describe RaydoService do
  let(:account) { create(:logistics_account, url1_base: "http://raydo.test:8082", username: "TEST", password: "123456") }

  it "authenticates and returns the customer ids" do
    stub_request(:get, "http://raydo.test:8082/selectAuth.htm").
      with(query: { username: "TEST", password: "123456" }).
      to_return(body: { customer_id: "6581", customer_userid: "6901", ack: "true" }.to_json,
                headers: { "Content-Type" => "application/json" })
    res = described_class.new(account).authenticate
    expect(res["customer_id"]).to eq("6581")
    expect(res["customer_userid"]).to eq("6901")
  end

  it "raises on ack=false" do
    stub_request(:get, "http://raydo.test:8082/selectAuth.htm").with(query: hash_including({})).
      to_return(body: { ack: "false" }.to_json, headers: { "Content-Type" => "application/json" })
    expect { described_class.new(account).authenticate }.to raise_error(RaydoService::Error)
  end

  it "lists products" do
    stub_request(:get, "http://raydo.test:8082/getProductList.htm").
      to_return(body: [ { product_id: "P1", product_shortname: "UK 小包" } ].to_json,
                headers: { "Content-Type" => "application/json" })
    list = described_class.new(account).product_list
    expect(list.first["product_id"]).to eq("P1")
  end
end
```
Ensure `spec/rails_helper.rb`/support enables WebMock (add `require "webmock/rspec"` in a support file if not already; if enabling globally breaks other specs that hit no external hosts, scope it — check the existing setup first and note in the report).

- [ ] **Step 4: Run + commit**
```bash
bundle exec rspec spec/services/raydo_service_spec.rb
bin/rubocop app/services/raydo_service.rb app/models/membership.rb app/controllers/admin_controller.rb
git add app/services/raydo_service.rb app/models/membership.rb app/controllers/admin_controller.rb spec
git commit -m "feat(logistics): RaydoService (auth + product list) and logistics_channels permission"
```

---

### Task 6: Logistics UI (account config + channel CRUD under Shipping)

**Files:**
- Create: `app/controllers/logistics_accounts_controller.rb`, `app/controllers/logistics_channels_controller.rb`
- Create: views under `app/views/logistics_accounts/`, `app/views/logistics_channels/`
- Modify: `config/routes.rb`, `app/views/shared/_sidebar.html.erb` (Shipping submenu), `config/locales/*.yml`
- Test: `spec/requests/logistics_accounts_spec.rb`, `spec/requests/logistics_channels_spec.rb`, `spec/system/logistics_channels_spec.rb`

**Interfaces:**
- Consumes: Tasks 4 (models) + 5 (RaydoService, permission).

- [ ] **Step 1: Routes**
```ruby
    resource :logistics_account, only: [ :show, :update ], controller: "logistics_accounts" do
      post :authenticate, on: :member
    end
    resources :logistics_channels, only: [ :index, :new, :create, :edit, :update, :destroy ] do
      get :product_options, on: :collection   # fetches Raydo getProductList for the dropdown
    end
```

- [ ] **Step 2: Sidebar** — add a "物流渠道" child to the Shipping nav-group (mirror an existing Shipping child), gated by `has_permission?("logistics_channels")`; add `logistics_channels`/`logistics_accounts` to the `shipping_active` whitelist and `has_shipping_items` condition. i18n `nav.logistics_channels` in all three locales.

- [ ] **Step 3: Controllers**
  - `LogisticsAccountsController`: `show` (find-or-init the company's raydo account), `update` (creds + urls), `authenticate` (calls `RaydoService#authenticate`, caches `customer_id`/`customer_userid`, flash success/error). Gate: `authorize_page!` via `logistics_channels` permission (owner-or-permission).
  - `LogisticsChannelsController`: standard CRUD scoped to the company's account; `product_options` calls `RaydoService.new(account).product_list` and returns JSON for the create/edit dropdown. Handle `RaydoService::Error` gracefully (flash / JSON error).
  - Scope everything to `current_company` (never expose another company's account/channels).

- [ ] **Step 4: Views** — account settings form (username/password/url1/url2 + a 測試認證 button hitting the `authenticate` member route); channel index (list) + new/edit form where `product_id` is a `<select>` populated from `product_options` (JSON) — show `product_shortname` as label, store `product_id`; plus 別稱, shopify_carrier_name (default Other), tracking_url_template (default 17track). Follow existing form styling (see `shopify_stores/show.html.erb`).

- [ ] **Step 5: Request specs** — CRUD happy paths; permission gate (member with `logistics_channels` allowed, without denied); `authenticate` action stubbed with WebMock caches the ids; `product_options` stubbed returns the list; cross-company isolation (a member of company A cannot read company B's channels).

- [ ] **Step 6: System spec** (`:js`) — with WebMock stubbing `getProductList`, create a channel by picking a product from the dropdown and saving; it appears in the list.

- [ ] **Step 7: Run + commit**
```bash
bundle exec rspec spec/requests/logistics_accounts_spec.rb spec/requests/logistics_channels_spec.rb spec/system/logistics_channels_spec.rb
bin/rubocop app/controllers/logistics_accounts_controller.rb app/controllers/logistics_channels_controller.rb
git add app/controllers/logistics_* app/views/logistics_* config/routes.rb app/views/shared/_sidebar.html.erb config/locales spec
git commit -m "feat(logistics): channel management UI with Raydo product dropdown"
```

---

## Verification (before PR)
- [ ] `bundle exec rspec` green, coverage ≥95%.
- [ ] `bin/rubocop`, `bin/brakeman --no-pager`, `bin/bundler-audit` clean.
- [ ] Manual: Products group shows 商品成本 + 報關信息; customs enforce-required works; logistics account auth + channel dropdown works (needs real Raydo creds — otherwise verify via the stubbed system spec).
- [ ] PR into `staging`.

## Self-Review notes
- **Spec coverage:** customs fields + `:customs` context (T1) ✓; `products` permission + nav-group + gate (T2) ✓; customs page + enforced-required single/bulk edit + incomplete filter (T3) ✓; logistics models + encrypts + unique (T4) ✓; RaydoService auth/product_list + permission (T5) ✓; account config + channel CRUD + Raydo dropdown + cross-company isolation (T6) ✓; i18n all locales per task ✓; system specs for Turbo UIs (T2/T3/T6) ✓.
- **Dependency:** live Raydo auth/product_list needs the production URL1/URL2 + username/password from the user. All tests use WebMock stubs, so implementation is not blocked; only manual end-to-end verification of the live dropdown needs the creds.
- **Type consistency:** `customs_name_zh/customs_name_en/declared_value_usd/hs_code/import_hs_code`, `customs_complete?`, `:customs` context, `product_customs_path`, `LogisticsAccount#authenticate/product_list` via `RaydoService`, `product_id`/`product_shortname` — used consistently across tasks.
- **Permission migration:** remapping products→`products` means existing `shopify_stores`-only members lose Products access until granted `products` (owner unaffected). Called out in T2; surface in the PR description.
