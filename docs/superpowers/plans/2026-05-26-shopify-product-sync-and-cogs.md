# Shopify Product Sync + Editable COGS / Weight — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync Shopify products at the shop dimension, allow editing per-SKU cost-of-goods and weight in the admin, snapshot COGS onto order line items, and surface gross/net profit on the dashboard.

**Architecture:** Three new tables (`products`, `product_variants`, `order_line_items`) with snapshotted unit cost frozen at order-sync time. Manual sync button per shop. Bulk-editable cost / weight UI on a paginated `/products` page. Dashboard rolls up COGS on the fly. Backfill is a console-run service.

**Tech Stack:** Rails 8.1, PostgreSQL (UUID PKs), Hotwire (Turbo Streams + Stimulus), Tailwind, RSpec + FactoryBot + WebMock, Solid Queue.

**Source spec:** `docs/superpowers/specs/2026-05-26-shopify-product-sync-and-cogs-design.md`

**Branch:** `feature/product-sync-and-cogs-design` (already created and contains the spec commit)

---

## File Structure

**Create:**
- `db/migrate/20260526000001_create_products.rb`
- `db/migrate/20260526000002_create_product_variants.rb`
- `db/migrate/20260526000003_create_order_line_items.rb`
- `db/migrate/20260526000004_add_products_sync_columns_to_shopify_stores.rb`
- `db/migrate/20260526000005_add_index_to_orders_store_and_ordered_at.rb`
- `app/models/product.rb`
- `app/models/product_variant.rb`
- `app/models/order_line_item.rb`
- `spec/factories/products.rb`
- `spec/factories/product_variants.rb`
- `spec/factories/order_line_items.rb`
- `spec/models/product_spec.rb`
- `spec/models/product_variant_spec.rb`
- `spec/models/order_line_item_spec.rb`
- `app/services/sync_shopify_products_service.rb`
- `spec/services/sync_shopify_products_service_spec.rb`
- `app/jobs/sync_shopify_products_job.rb`
- `spec/jobs/sync_shopify_products_job_spec.rb`
- `app/services/backfill_order_line_items_service.rb`
- `spec/services/backfill_order_line_items_service_spec.rb`
- `app/controllers/products_controller.rb`
- `app/controllers/product_variants_controller.rb`
- `app/views/products/index.html.erb`
- `app/views/product_variants/_row.html.erb`
- `app/views/product_variants/update.turbo_stream.erb`
- `app/javascript/controllers/auto_submit_controller.js`
- `app/javascript/controllers/bulk_select_controller.js`
- `spec/requests/products_spec.rb`
- `spec/requests/product_variants_spec.rb`
- `spec/system/products_spec.rb`

**Modify:**
- `app/services/shopify_service.rb` — add `fetch_all_products`, `fetch_inventory_items`, `fetch_shop`
- `app/services/sync_all_orders_service.rb` — call `sync_line_items` inside `sync_order`
- `app/models/shopify_store.rb` — `has_many :products`
- `app/models/order.rb` — `has_many :order_line_items`, profit methods
- `app/controllers/shopify_stores_controller.rb` — `sync_products` action
- `app/views/shopify_stores/show.html.erb` — Products section + sync button
- `app/services/dashboard_metrics_service.rb` — COGS aggregation
- `app/views/dashboard/show.html.erb` — Gross/Net profit cards + coverage
- `config/routes.rb` — new routes
- `config/locales/en.yml`, `zh-TW.yml`, `zh-CN.yml` — new keys
- `spec/services/sync_all_orders_service_spec.rb` — line items coverage
- `spec/services/dashboard_metrics_service_spec.rb` — COGS / gross / net assertions
- `spec/services/shopify_service_spec.rb` — new methods
- `spec/requests/shopify_stores_spec.rb` — `sync_products` action

---

## Task 1 — Migrations

**Files:**
- Create: `db/migrate/20260526000001_create_products.rb`
- Create: `db/migrate/20260526000002_create_product_variants.rb`
- Create: `db/migrate/20260526000003_create_order_line_items.rb`
- Create: `db/migrate/20260526000004_add_products_sync_columns_to_shopify_stores.rb`
- Create: `db/migrate/20260526000005_add_index_to_orders_store_and_ordered_at.rb`

- [ ] **Step 1 — Write `create_products` migration**

```ruby
class CreateProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :products, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid    :shopify_store_id, null: false
      t.bigint  :shopify_product_id, null: false
      t.string  :title
      t.string  :handle
      t.string  :status
      t.string  :image_url
      t.jsonb   :shopify_data, default: {}
      t.timestamps
    end
    add_index :products, [:shopify_store_id, :shopify_product_id], unique: true, name: "idx_products_store_shopify_id"
    add_index :products, :shopify_store_id
    add_foreign_key :products, :shopify_stores
  end
end
```

- [ ] **Step 2 — Write `create_product_variants` migration**

```ruby
class CreateProductVariants < ActiveRecord::Migration[8.1]
  def change
    create_table :product_variants, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid    :product_id, null: false
      t.bigint  :shopify_variant_id, null: false
      t.bigint  :shopify_inventory_item_id
      t.string  :sku
      t.string  :title
      t.decimal :price, precision: 10, scale: 2
      t.string  :currency
      t.decimal :shopify_cost, precision: 10, scale: 2
      t.decimal :unit_cost, precision: 10, scale: 2
      t.decimal :shopify_weight_grams, precision: 12, scale: 3
      t.decimal :weight_grams, precision: 12, scale: 3
      t.jsonb   :shopify_data, default: {}
      t.timestamps
    end
    add_index :product_variants, [:product_id, :shopify_variant_id], unique: true, name: "idx_variants_product_shopify_id"
    add_index :product_variants, :sku
    add_index :product_variants, :shopify_inventory_item_id
    add_foreign_key :product_variants, :products
  end
end
```

- [ ] **Step 3 — Write `create_order_line_items` migration**

```ruby
class CreateOrderLineItems < ActiveRecord::Migration[8.1]
  def change
    create_table :order_line_items, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid    :order_id, null: false
      t.uuid    :product_variant_id
      t.bigint  :shopify_line_item_id, null: false
      t.string  :sku_at_sale
      t.string  :title_at_sale
      t.integer :quantity, null: false
      t.decimal :unit_price, precision: 10, scale: 2
      t.decimal :unit_cost_snapshot, precision: 10, scale: 2
      t.string  :currency
      t.jsonb   :shopify_data, default: {}
      t.timestamps
    end
    add_index :order_line_items, [:order_id, :shopify_line_item_id], unique: true, name: "idx_line_items_order_shopify_id"
    add_index :order_line_items, :product_variant_id
    add_foreign_key :order_line_items, :orders
    add_foreign_key :order_line_items, :product_variants
  end
end
```

- [ ] **Step 4 — Write `add_products_sync_columns_to_shopify_stores` migration**

```ruby
class AddProductsSyncColumnsToShopifyStores < ActiveRecord::Migration[8.1]
  def change
    add_column :shopify_stores, :products_synced_at, :datetime
    add_column :shopify_stores, :currency, :string
  end
end
```

- [ ] **Step 5 — Write `add_index_to_orders_store_and_ordered_at` migration**

```ruby
class AddIndexToOrdersStoreAndOrderedAt < ActiveRecord::Migration[8.1]
  def change
    add_index :orders, [:shopify_store_id, :ordered_at],
              name: "idx_orders_store_ordered_at",
              if_not_exists: true
  end
end
```

- [ ] **Step 6 — Run migrations**

Run: `bin/rails db:migrate`
Expected: All five migrations run cleanly, no errors. Schema version becomes `20260526000005`.

- [ ] **Step 7 — Prepare test DB**

Run: `bin/rails db:test:prepare`
Expected: Test DB schema matches.

- [ ] **Step 8 — Commit**

```bash
git add db/migrate/20260526000001_*.rb db/migrate/20260526000002_*.rb db/migrate/20260526000003_*.rb db/migrate/20260526000004_*.rb db/migrate/20260526000005_*.rb db/schema.rb
git commit -m "db: schema for products, variants, order line items"
```

---

## Task 2 — `Product` model + factory + spec

**Files:**
- Create: `app/models/product.rb`
- Create: `spec/factories/products.rb`
- Create: `spec/models/product_spec.rb`

- [ ] **Step 1 — Write the failing model spec**

`spec/models/product_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Product, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:shopify_store) }
    it { is_expected.to have_many(:product_variants).dependent(:destroy) }
  end

  describe "validations" do
    subject { build(:product) }
    it { is_expected.to validate_presence_of(:shopify_product_id) }
  end

  describe "uniqueness of shopify_product_id within a store" do
    it "rejects duplicates within the same store" do
      product = create(:product)
      dup = build(:product, shopify_store: product.shopify_store, shopify_product_id: product.shopify_product_id)
      expect(dup).not_to be_valid_or_save_via_db
    rescue ActiveRecord::RecordNotUnique
      # acceptable — unique index enforces it
    end

    it "allows the same shopify_product_id in different stores" do
      a = create(:product)
      b = create(:product, shopify_product_id: a.shopify_product_id)
      expect(b).to be_persisted
    end
  end
end
```

Note: helper `be_valid_or_save_via_db` is not standard. Replace the first example with the simpler form that uses the DB-level constraint:

```ruby
it "rejects duplicates within the same store via DB index" do
  product = create(:product)
  expect {
    create(:product, shopify_store: product.shopify_store, shopify_product_id: product.shopify_product_id)
  }.to raise_error(ActiveRecord::RecordNotUnique)
end
```

- [ ] **Step 2 — Run spec to verify it fails**

Run: `bundle exec rspec spec/models/product_spec.rb`
Expected: FAIL — `uninitialized constant Product` (or factory not found).

- [ ] **Step 3 — Create the factory**

`spec/factories/products.rb`:

```ruby
FactoryBot.define do
  factory :product do
    shopify_store
    sequence(:shopify_product_id) { |n| 7000 + n }
    sequence(:title) { |n| "Paint Kit #{n}" }
    handle { title.parameterize }
    status { "active" }
    image_url { nil }
    shopify_data { {} }
  end
end
```

- [ ] **Step 4 — Create the model**

`app/models/product.rb`:

```ruby
class Product < ApplicationRecord
  belongs_to :shopify_store
  has_many :product_variants, dependent: :destroy

  validates :shopify_product_id, presence: true
end
```

- [ ] **Step 5 — Wire the association into `ShopifyStore`**

Modify `app/models/shopify_store.rb`, add inside the class:

```ruby
has_many :products, dependent: :destroy
```

- [ ] **Step 6 — Run spec to verify it passes**

Run: `bundle exec rspec spec/models/product_spec.rb`
Expected: PASS (all examples).

- [ ] **Step 7 — Commit**

```bash
git add app/models/product.rb app/models/shopify_store.rb spec/factories/products.rb spec/models/product_spec.rb
git commit -m "models: Product belongs_to shopify_store with unique shopify_product_id"
```

---

## Task 3 — `ProductVariant` model + factory + spec

**Files:**
- Create: `app/models/product_variant.rb`
- Create: `spec/factories/product_variants.rb`
- Create: `spec/models/product_variant_spec.rb`

- [ ] **Step 1 — Write the failing spec**

`spec/models/product_variant_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe ProductVariant, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:product) }
    it { is_expected.to have_one(:shopify_store).through(:product) }
    it { is_expected.to have_many(:order_line_items).dependent(:nullify) }
  end

  describe "validations" do
    subject { build(:product_variant) }
    it { is_expected.to validate_presence_of(:shopify_variant_id) }
    it { is_expected.to validate_numericality_of(:unit_cost).is_greater_than_or_equal_to(0).allow_nil }
    it { is_expected.to validate_numericality_of(:weight_grams).is_greater_than(0).allow_nil }
  end

  it "rejects duplicate shopify_variant_id within the same product (DB index)" do
    v = create(:product_variant)
    expect {
      create(:product_variant, product: v.product, shopify_variant_id: v.shopify_variant_id)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
```

- [ ] **Step 2 — Run spec to verify it fails**

Run: `bundle exec rspec spec/models/product_variant_spec.rb`
Expected: FAIL — `uninitialized constant ProductVariant`.

- [ ] **Step 3 — Create the factory**

`spec/factories/product_variants.rb`:

```ruby
FactoryBot.define do
  factory :product_variant do
    product
    sequence(:shopify_variant_id)         { |n| 8000 + n }
    sequence(:shopify_inventory_item_id)  { |n| 9000 + n }
    sequence(:sku) { |n| "SKU-#{n}" }
    title { "Default" }
    price { 29.99 }
    currency { "USD" }
    shopify_cost { nil }
    unit_cost { nil }
    shopify_weight_grams { 250 }
    weight_grams { nil }
    shopify_data { {} }
  end
end
```

- [ ] **Step 4 — Create the model**

`app/models/product_variant.rb`:

```ruby
class ProductVariant < ApplicationRecord
  belongs_to :product
  has_one  :shopify_store, through: :product
  has_many :order_line_items, dependent: :nullify

  validates :shopify_variant_id, presence: true
  validates :unit_cost,    numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :weight_grams, numericality: { greater_than: 0,            allow_nil: true }
end
```

- [ ] **Step 5 — Run spec to verify it passes**

Run: `bundle exec rspec spec/models/product_variant_spec.rb`
Expected: PASS.

- [ ] **Step 6 — Commit**

```bash
git add app/models/product_variant.rb spec/factories/product_variants.rb spec/models/product_variant_spec.rb
git commit -m "models: ProductVariant with cost/weight validation and unique shopify_variant_id"
```

---

## Task 4 — `OrderLineItem` model + factory + spec

**Files:**
- Create: `app/models/order_line_item.rb`
- Create: `spec/factories/order_line_items.rb`
- Create: `spec/models/order_line_item_spec.rb`

- [ ] **Step 1 — Write the failing spec**

`spec/models/order_line_item_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe OrderLineItem, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:order) }
    it { is_expected.to belong_to(:product_variant).optional }
  end

  describe "validations" do
    subject { build(:order_line_item) }
    it { is_expected.to validate_presence_of(:shopify_line_item_id) }
    it { is_expected.to validate_numericality_of(:quantity).is_greater_than(0) }
  end

  it "allows nil product_variant" do
    line_item = build(:order_line_item, product_variant: nil)
    expect(line_item).to be_valid
  end

  it "rejects duplicate shopify_line_item_id within the same order (DB index)" do
    li = create(:order_line_item)
    expect {
      create(:order_line_item, order: li.order, shopify_line_item_id: li.shopify_line_item_id)
    }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
```

- [ ] **Step 2 — Run spec to verify it fails**

Run: `bundle exec rspec spec/models/order_line_item_spec.rb`
Expected: FAIL — `uninitialized constant OrderLineItem`.

- [ ] **Step 3 — Create the factory**

`spec/factories/order_line_items.rb`:

```ruby
FactoryBot.define do
  factory :order_line_item do
    order
    product_variant { nil }
    sequence(:shopify_line_item_id) { |n| 6000 + n }
    sequence(:sku_at_sale) { |n| "SOLD-#{n}" }
    title_at_sale { "Sample Item" }
    quantity { 1 }
    unit_price { 29.99 }
    unit_cost_snapshot { nil }
    currency { "USD" }
    shopify_data { {} }
  end
end
```

- [ ] **Step 4 — Create the model**

`app/models/order_line_item.rb`:

```ruby
class OrderLineItem < ApplicationRecord
  belongs_to :order
  belongs_to :product_variant, optional: true

  validates :shopify_line_item_id, presence: true
  validates :quantity, presence: true, numericality: { greater_than: 0 }
end
```

- [ ] **Step 5 — Wire associations into `Order`**

Modify `app/models/order.rb`, add inside the class:

```ruby
has_many :order_line_items, dependent: :destroy
```

- [ ] **Step 6 — Run spec to verify it passes**

Run: `bundle exec rspec spec/models/order_line_item_spec.rb`
Expected: PASS.

- [ ] **Step 7 — Commit**

```bash
git add app/models/order_line_item.rb app/models/order.rb spec/factories/order_line_items.rb spec/models/order_line_item_spec.rb
git commit -m "models: OrderLineItem with quantity validation and unique shopify_line_item_id"
```

---

## Task 5 — `Order` profit methods + spec

**Files:**
- Modify: `app/models/order.rb`
- Modify: `spec/models/order_spec.rb` (extend existing if present, else create)

- [ ] **Step 1 — Add failing examples**

If `spec/models/order_spec.rb` does not exist, create it with `require "rails_helper"` and the wrapper `RSpec.describe Order, type: :model do ... end`. Add inside the describe block:

```ruby
describe "profit methods" do
  let(:order) { create(:order, total_price: 100) }

  it "#cogs_total sums quantity * unit_cost_snapshot" do
    create(:order_line_item, order: order, quantity: 2, unit_cost_snapshot: 10)
    create(:order_line_item, order: order, quantity: 1, unit_cost_snapshot: 5)
    expect(order.cogs_total).to eq(25)
  end

  it "#cogs_total treats null snapshots as 0" do
    create(:order_line_item, order: order, quantity: 2, unit_cost_snapshot: nil)
    create(:order_line_item, order: order, quantity: 1, unit_cost_snapshot: 5)
    expect(order.cogs_total).to eq(5)
  end

  it "#gross_profit = total_price - cogs_total" do
    create(:order_line_item, order: order, quantity: 1, unit_cost_snapshot: 30)
    expect(order.gross_profit).to eq(70)
  end

  it "#gross_profit returns nil when total_price is nil" do
    nil_order = create(:order, total_price: nil)
    expect(nil_order.gross_profit).to be_nil
  end

  it "#gross_margin_pct = gross_profit / total_price * 100" do
    create(:order_line_item, order: order, quantity: 1, unit_cost_snapshot: 30)
    expect(order.gross_margin_pct).to eq(70.0)
  end

  it "#gross_margin_pct returns nil when total_price is 0 or nil" do
    zero_order = create(:order, total_price: 0)
    expect(zero_order.gross_margin_pct).to be_nil
  end

  it "#cogs_complete? is true when all snapshots set" do
    create(:order_line_item, order: order, unit_cost_snapshot: 1)
    expect(order.cogs_complete?).to be true
  end

  it "#cogs_complete? is false when any snapshot is null" do
    create(:order_line_item, order: order, unit_cost_snapshot: nil)
    expect(order.cogs_complete?).to be false
  end
end
```

- [ ] **Step 2 — Run spec to verify it fails**

Run: `bundle exec rspec spec/models/order_spec.rb -e "profit methods"`
Expected: FAIL — `undefined method 'cogs_total'`.

- [ ] **Step 3 — Add the methods to `Order`**

Modify `app/models/order.rb`. Add inside the class:

```ruby
def cogs_total
  order_line_items.sum("quantity * COALESCE(unit_cost_snapshot, 0)")
end

def gross_profit
  return nil unless total_price
  total_price - cogs_total
end

def gross_margin_pct
  return nil unless total_price && total_price.positive?
  (gross_profit / total_price * 100).round(2)
end

def cogs_complete?
  !order_line_items.where(unit_cost_snapshot: nil).exists?
end
```

- [ ] **Step 4 — Run spec to verify it passes**

Run: `bundle exec rspec spec/models/order_spec.rb -e "profit methods"`
Expected: PASS.

- [ ] **Step 5 — Commit**

```bash
git add app/models/order.rb spec/models/order_spec.rb
git commit -m "models: Order profit methods (cogs_total, gross_profit, margin, completeness)"
```

---

## Task 6 — `ShopifyService` API additions

**Files:**
- Modify: `app/services/shopify_service.rb`
- Modify: `spec/services/shopify_service_spec.rb`

- [ ] **Step 1 — Add failing examples**

Append to `spec/services/shopify_service_spec.rb` inside the existing `RSpec.describe ShopifyService` block:

```ruby
describe "#fetch_all_products" do
  let(:store) { create(:shopify_store, shop_domain: "test-shop.myshopify.com", access_token: "tok") }
  let(:service) { described_class.new(store) }

  it "GETs /products.json and returns the products array" do
    stub_request(:get, "https://test-shop.myshopify.com/admin/api/2024-10/products.json")
      .with(query: { limit: 250, order: "id asc" })
      .to_return(status: 200, body: { products: [{ "id" => 1 }] }.to_json,
                 headers: { "Content-Type" => "application/json" })
    expect(service.fetch_all_products).to eq([{ "id" => 1 }])
  end

  it "passes since_id when given" do
    stub_request(:get, "https://test-shop.myshopify.com/admin/api/2024-10/products.json")
      .with(query: { limit: 250, order: "id asc", since_id: 42 })
      .to_return(status: 200, body: { products: [] }.to_json,
                 headers: { "Content-Type" => "application/json" })
    expect(service.fetch_all_products(since_id: 42)).to eq([])
  end
end

describe "#fetch_inventory_items" do
  let(:store) { create(:shopify_store, shop_domain: "test-shop.myshopify.com", access_token: "tok") }
  let(:service) { described_class.new(store) }

  it "returns [] when ids is empty without calling Shopify" do
    expect(service.fetch_inventory_items(ids: [])).to eq([])
  end

  it "GETs /inventory_items.json with comma-joined ids" do
    stub_request(:get, "https://test-shop.myshopify.com/admin/api/2024-10/inventory_items.json")
      .with(query: { ids: "1,2,3" })
      .to_return(status: 200,
                 body: { inventory_items: [{ "id" => 1, "cost" => "5.00" }] }.to_json,
                 headers: { "Content-Type" => "application/json" })
    expect(service.fetch_inventory_items(ids: [1, 2, 3])).to eq([{ "id" => 1, "cost" => "5.00" }])
  end
end

describe "#fetch_shop" do
  let(:store) { create(:shopify_store, shop_domain: "test-shop.myshopify.com", access_token: "tok") }
  let(:service) { described_class.new(store) }

  it "GETs /shop.json and returns the shop hash" do
    stub_request(:get, "https://test-shop.myshopify.com/admin/api/2024-10/shop.json")
      .to_return(status: 200, body: { shop: { "currency" => "USD" } }.to_json,
                 headers: { "Content-Type" => "application/json" })
    expect(service.fetch_shop).to eq({ "currency" => "USD" })
  end
end
```

- [ ] **Step 2 — Run spec to verify it fails**

Run: `bundle exec rspec spec/services/shopify_service_spec.rb -e "fetch_all_products"`
Expected: FAIL — `undefined method 'fetch_all_products'`.

- [ ] **Step 3 — Add methods to `ShopifyService`**

In `app/services/shopify_service.rb`, before the existing `register_webhook` method, add:

```ruby
def fetch_all_products(limit: 250, since_id: nil)
  params = { limit: limit, order: "id asc" }
  params[:since_id] = since_id if since_id
  response = get("/products.json", **params)
  response["products"] || []
end

def fetch_inventory_items(ids:)
  return [] if ids.empty?
  response = get("/inventory_items.json", ids: ids.join(","))
  response["inventory_items"] || []
end

def fetch_shop
  response = get("/shop.json")
  response["shop"] || {}
end
```

- [ ] **Step 4 — Run spec to verify it passes**

Run: `bundle exec rspec spec/services/shopify_service_spec.rb`
Expected: PASS (all new examples + the existing ones).

- [ ] **Step 5 — Commit**

```bash
git add app/services/shopify_service.rb spec/services/shopify_service_spec.rb
git commit -m "shopify_service: add fetch_all_products, fetch_inventory_items, fetch_shop"
```

---

## Task 7 — `SyncShopifyProductsService`

**Files:**
- Create: `app/services/sync_shopify_products_service.rb`
- Create: `spec/services/sync_shopify_products_service_spec.rb`

- [ ] **Step 1 — Write the failing spec**

```ruby
require "rails_helper"

RSpec.describe SyncShopifyProductsService do
  let(:store) { create(:shopify_store) }
  let(:shopify_service) { instance_double(ShopifyService) }
  let(:service) { described_class.new(store) }

  before do
    allow(ShopifyService).to receive(:new).with(store).and_return(shopify_service)
    allow(shopify_service).to receive(:fetch_shop).and_return({ "currency" => "USD" })
  end

  let(:variant_a) do
    { "id" => 8001, "inventory_item_id" => 9001, "sku" => "PK-BL",
      "title" => "Black/Large", "price" => "29.00", "grams" => 450 }
  end
  let(:variant_b) do
    { "id" => 8002, "inventory_item_id" => 9002, "sku" => "PK-BS",
      "title" => "Black/Small", "price" => "24.00", "grams" => 320 }
  end
  let(:product_payload) do
    { "id" => 7001, "title" => "Paint Kit", "handle" => "paint-kit",
      "status" => "active", "image" => { "src" => "https://cdn/x.jpg" },
      "variants" => [variant_a, variant_b] }
  end

  before do
    allow(shopify_service).to receive(:fetch_all_products).and_return([product_payload], [])
    allow(shopify_service).to receive(:fetch_inventory_items)
      .with(ids: [9001, 9002])
      .and_return([
        { "id" => 9001, "cost" => "12.50" },
        { "id" => 9002, "cost" => "10.00" }
      ])
  end

  it "creates products, variants, and shopify_cost" do
    service.call
    p = Product.find_by(shopify_product_id: 7001)
    expect(p.shopify_store).to eq(store)
    expect(p.product_variants.count).to eq(2)
    expect(p.product_variants.find_by(shopify_variant_id: 8001).shopify_cost).to eq(12.50)
  end

  it "updates store currency from /shop.json" do
    expect { service.call }.to change { store.reload.currency }.to("USD")
  end

  it "sets products_synced_at" do
    expect { service.call }.to change { store.reload.products_synced_at }.from(nil)
  end

  it "returns counts" do
    expect(service.call).to eq(products: 1, variants: 2)
  end

  it "is idempotent — no duplicates on re-run" do
    service.call
    allow(shopify_service).to receive(:fetch_all_products).and_return([product_payload], [])
    expect { described_class.new(store).call }.not_to change(Product, :count)
  end

  it "does not overwrite admin-edited unit_cost or weight_grams" do
    service.call
    variant = ProductVariant.find_by(shopify_variant_id: 8001)
    variant.update!(unit_cost: 99.99, weight_grams: 500)

    allow(shopify_service).to receive(:fetch_all_products).and_return([product_payload], [])
    described_class.new(store).call

    variant.reload
    expect(variant.unit_cost).to eq(99.99)
    expect(variant.weight_grams).to eq(500)
  end
end
```

- [ ] **Step 2 — Run spec to verify it fails**

Run: `bundle exec rspec spec/services/sync_shopify_products_service_spec.rb`
Expected: FAIL — `uninitialized constant SyncShopifyProductsService`.

- [ ] **Step 3 — Create the service**

`app/services/sync_shopify_products_service.rb`:

```ruby
class SyncShopifyProductsService
  INVENTORY_BATCH = 100

  def initialize(shopify_store)
    @store = shopify_store
    @shopify = ShopifyService.new(shopify_store)
    @synced_products = 0
    @synced_variants = 0
  end

  def call
    Rails.logger.info("[SyncProducts] start store=#{@store.shop_domain}")
    sync_started_at = Time.current

    update_store_currency
    sync_all_products
    apply_inventory_costs

    @store.update!(products_synced_at: sync_started_at)
    Rails.logger.info("[SyncProducts] done #{@synced_products} products, #{@synced_variants} variants")
    { products: @synced_products, variants: @synced_variants }
  end

  private

  def update_store_currency
    shop = @shopify.fetch_shop
    @store.update!(currency: shop["currency"]) if shop["currency"].present?
  end

  def sync_all_products
    since_id = nil
    loop do
      batch = @shopify.fetch_all_products(since_id: since_id)
      break if batch.empty?
      batch.each { |sp| upsert_product(sp) }
      since_id = batch.last["id"]
      break if batch.size < 250
    end
  end

  def upsert_product(sp)
    product = @store.products.find_or_initialize_by(shopify_product_id: sp["id"])
    product.assign_attributes(
      title: sp["title"], handle: sp["handle"], status: sp["status"],
      image_url: sp.dig("image", "src"), shopify_data: sp
    )
    product.save!
    @synced_products += 1

    (sp["variants"] || []).each { |sv| upsert_variant(product, sv) }
  end

  def upsert_variant(product, sv)
    variant = product.product_variants.find_or_initialize_by(shopify_variant_id: sv["id"])
    variant.shopify_inventory_item_id = sv["inventory_item_id"]
    variant.sku = sv["sku"]
    variant.title = sv["title"]
    variant.price = sv["price"]
    variant.currency = @store.currency
    variant.shopify_weight_grams = sv["grams"]
    variant.shopify_data = sv
    # NEVER overwrite admin-edited unit_cost / weight_grams
    variant.save!
    @synced_variants += 1
  end

  def apply_inventory_costs
    variants = ProductVariant.joins(:product)
                             .where(products: { shopify_store_id: @store.id })
                             .where.not(shopify_inventory_item_id: nil)
    variants.pluck(:shopify_inventory_item_id).uniq.each_slice(INVENTORY_BATCH) do |ids|
      @shopify.fetch_inventory_items(ids: ids).each do |item|
        ProductVariant.where(shopify_inventory_item_id: item["id"])
                      .update_all(shopify_cost: item["cost"])
      end
    end
  end
end
```

- [ ] **Step 4 — Run spec to verify it passes**

Run: `bundle exec rspec spec/services/sync_shopify_products_service_spec.rb`
Expected: PASS (all examples).

- [ ] **Step 5 — Commit**

```bash
git add app/services/sync_shopify_products_service.rb spec/services/sync_shopify_products_service_spec.rb
git commit -m "service: SyncShopifyProductsService upserts products/variants and inventory costs"
```

---

## Task 8 — `SyncShopifyProductsJob`

**Files:**
- Create: `app/jobs/sync_shopify_products_job.rb`
- Create: `spec/jobs/sync_shopify_products_job_spec.rb`

- [ ] **Step 1 — Write the failing spec**

```ruby
require "rails_helper"

RSpec.describe SyncShopifyProductsJob do
  let(:store) { create(:shopify_store) }

  it "invokes SyncShopifyProductsService with the store" do
    service = instance_double(SyncShopifyProductsService, call: nil)
    expect(SyncShopifyProductsService).to receive(:new).with(an_instance_of(ShopifyStore)).and_return(service)
    described_class.new.perform(store.id)
  end
end
```

- [ ] **Step 2 — Run to verify it fails**

Run: `bundle exec rspec spec/jobs/sync_shopify_products_job_spec.rb`
Expected: FAIL — `uninitialized constant SyncShopifyProductsJob`.

- [ ] **Step 3 — Create the job**

`app/jobs/sync_shopify_products_job.rb`:

```ruby
class SyncShopifyProductsJob < ApplicationJob
  queue_as :default

  def perform(shopify_store_id)
    store = ShopifyStore.find(shopify_store_id)
    SyncShopifyProductsService.new(store).call
  end
end
```

- [ ] **Step 4 — Run to verify it passes**

Run: `bundle exec rspec spec/jobs/sync_shopify_products_job_spec.rb`
Expected: PASS.

- [ ] **Step 5 — Commit**

```bash
git add app/jobs/sync_shopify_products_job.rb spec/jobs/sync_shopify_products_job_spec.rb
git commit -m "job: SyncShopifyProductsJob wraps SyncShopifyProductsService"
```

---

## Task 9 — Line item sync in `SyncAllOrdersService`

**Files:**
- Modify: `app/services/sync_all_orders_service.rb`
- Modify: `spec/services/sync_all_orders_service_spec.rb`

- [ ] **Step 1 — Add failing examples**

Append to `spec/services/sync_all_orders_service_spec.rb` inside the existing `describe "#call"` block:

```ruby
context "line items" do
  let!(:product) { create(:product, shopify_store: store, shopify_product_id: 7001) }
  let!(:variant_a) do
    create(:product_variant, product: product, shopify_variant_id: 8001, unit_cost: 12.50)
  end

  let(:shopify_order_with_lines) do
    shopify_order.merge(
      "line_items" => [
        { "id" => 6001, "variant_id" => 8001, "sku" => "PK-BL", "title" => "Paint / Black",
          "quantity" => 2, "price" => "29.00" },
        { "id" => 6002, "variant_id" => 9999, "sku" => "UNKNOWN", "title" => "Mystery",
          "quantity" => 1, "price" => "15.00" }
      ]
    )
  end

  before do
    allow(shopify_service).to receive(:fetch_all_orders).and_return([shopify_order_with_lines], [])
  end

  it "creates OrderLineItem rows from each line item in the shopify payload" do
    expect { service.call }.to change(OrderLineItem, :count).by(2)
  end

  it "snapshots unit_cost from matching variant" do
    service.call
    li = OrderLineItem.find_by(shopify_line_item_id: 6001)
    expect(li.product_variant).to eq(variant_a)
    expect(li.unit_cost_snapshot).to eq(12.50)
    expect(li.quantity).to eq(2)
    expect(li.unit_price).to eq(29.00)
  end

  it "saves the line item with null variant when shopify variant_id is unknown" do
    service.call
    li = OrderLineItem.find_by(shopify_line_item_id: 6002)
    expect(li.product_variant).to be_nil
    expect(li.unit_cost_snapshot).to be_nil
    expect(li.sku_at_sale).to eq("UNKNOWN")
  end

  it "does not overwrite existing snapshot on re-sync" do
    service.call
    OrderLineItem.find_by(shopify_line_item_id: 6001).update!(unit_cost_snapshot: 7.77)

    allow(shopify_service).to receive(:fetch_all_orders).and_return([shopify_order_with_lines], [])
    described_class.new(store).call

    expect(OrderLineItem.find_by(shopify_line_item_id: 6001).unit_cost_snapshot).to eq(7.77)
  end
end
```

- [ ] **Step 2 — Run to verify it fails**

Run: `bundle exec rspec spec/services/sync_all_orders_service_spec.rb -e "line items"`
Expected: FAIL — `OrderLineItem.count` change is 0 (line items not synced yet).

- [ ] **Step 3 — Modify `SyncAllOrdersService#sync_order`**

In `app/services/sync_all_orders_service.rb`, inside `sync_order`, after the `save!` / rescue block but before the `sync_fulfillments(order, shopify_order)` call, insert:

```ruby
sync_line_items(order, shopify_order)
```

- [ ] **Step 4 — Add private helpers to the service**

At the bottom of the same file (before the closing `end`), add:

```ruby
def sync_line_items(order, shopify_order)
  (shopify_order["line_items"] || []).each do |li|
    variant = variant_lookup[li["variant_id"]]

    line_item = order.order_line_items.find_or_initialize_by(shopify_line_item_id: li["id"])
    line_item.assign_attributes(
      product_variant: variant,
      sku_at_sale:   li["sku"],
      title_at_sale: li["title"],
      quantity:      li["quantity"],
      unit_price:    li["price"],
      currency:      shopify_order["currency"],
      shopify_data:  li
    )

    if line_item.unit_cost_snapshot.nil? && variant&.unit_cost.present?
      line_item.unit_cost_snapshot = variant.unit_cost
    end

    line_item.save!
  end
end

def variant_lookup
  @variant_lookup ||= ProductVariant.joins(:product)
                                    .where(products: { shopify_store_id: @store.id })
                                    .index_by(&:shopify_variant_id)
end
```

- [ ] **Step 5 — Run to verify it passes**

Run: `bundle exec rspec spec/services/sync_all_orders_service_spec.rb`
Expected: PASS (new examples + existing ones).

- [ ] **Step 6 — Commit**

```bash
git add app/services/sync_all_orders_service.rb spec/services/sync_all_orders_service_spec.rb
git commit -m "sync_all_orders: extract line items and snapshot unit cost on sync"
```

---

## Task 10 — `BackfillOrderLineItemsService`

**Files:**
- Create: `app/services/backfill_order_line_items_service.rb`
- Create: `spec/services/backfill_order_line_items_service_spec.rb`

- [ ] **Step 1 — Write the failing spec**

```ruby
require "rails_helper"

RSpec.describe BackfillOrderLineItemsService do
  let(:store) { create(:shopify_store) }
  let(:customer) { create(:customer, shopify_store: store) }
  let!(:product) { create(:product, shopify_store: store, shopify_product_id: 7001) }
  let!(:variant) do
    create(:product_variant, product: product, shopify_variant_id: 8001, unit_cost: 10.00)
  end

  let(:line_items_payload) do
    [
      { "id" => 6001, "variant_id" => 8001, "sku" => "PK-BL", "title" => "Black",
        "quantity" => 3, "price" => "29.00" },
      { "id" => 6002, "variant_id" => 9999, "sku" => "MYST",  "title" => "Mystery",
        "quantity" => 1, "price" => "15.00" }
    ]
  end

  let!(:order) do
    create(:order, customer: customer, shopify_store: store, currency: "USD",
                   shopify_data: { "line_items" => line_items_payload })
  end

  it "creates OrderLineItem rows from orders.shopify_data" do
    expect { described_class.new(store).call }.to change(OrderLineItem, :count).by(2)
  end

  it "snapshots current unit_cost when variant is known" do
    described_class.new(store).call
    li = order.order_line_items.find_by(shopify_line_item_id: 6001)
    expect(li.unit_cost_snapshot).to eq(10.00)
    expect(li.product_variant).to eq(variant)
  end

  it "leaves snapshot null when variant is unknown" do
    described_class.new(store).call
    li = order.order_line_items.find_by(shopify_line_item_id: 6002)
    expect(li.unit_cost_snapshot).to be_nil
    expect(li.product_variant).to be_nil
  end

  it "is idempotent — does not duplicate or overwrite snapshots" do
    described_class.new(store).call
    order.order_line_items.find_by(shopify_line_item_id: 6001).update!(unit_cost_snapshot: 7.77)

    described_class.new(store).call

    expect(order.order_line_items.count).to eq(2)
    expect(order.order_line_items.find_by(shopify_line_item_id: 6001).unit_cost_snapshot).to eq(7.77)
  end

  it "returns counts" do
    result = described_class.new(store).call
    expect(result[:orders]).to eq(1)
    expect(result[:snapshotted]).to eq(1)
  end
end
```

- [ ] **Step 2 — Run to verify it fails**

Run: `bundle exec rspec spec/services/backfill_order_line_items_service_spec.rb`
Expected: FAIL — `uninitialized constant BackfillOrderLineItemsService`.

- [ ] **Step 3 — Create the service**

`app/services/backfill_order_line_items_service.rb`:

```ruby
class BackfillOrderLineItemsService
  def initialize(shopify_store)
    @store = shopify_store
    @processed = 0
    @snapshotted = 0
  end

  def call
    Rails.logger.info("[BackfillLineItems] start store=#{@store.shop_domain}")
    @store.orders.find_each(batch_size: 200) do |order|
      (order.shopify_data&.dig("line_items") || []).each { |li| upsert_line_item(order, li) }
      @processed += 1
    end
    Rails.logger.info("[BackfillLineItems] done orders=#{@processed} snapshotted=#{@snapshotted}")
    { orders: @processed, snapshotted: @snapshotted }
  end

  private

  def upsert_line_item(order, li)
    variant = variant_lookup[li["variant_id"]]
    line_item = order.order_line_items.find_or_initialize_by(shopify_line_item_id: li["id"])
    line_item.assign_attributes(
      product_variant: variant,
      sku_at_sale:   li["sku"],
      title_at_sale: li["title"],
      quantity:      li["quantity"],
      unit_price:    li["price"],
      currency:      order.currency,
      shopify_data:  li
    )
    if line_item.unit_cost_snapshot.nil? && variant&.unit_cost.present?
      line_item.unit_cost_snapshot = variant.unit_cost
      @snapshotted += 1
    end
    line_item.save!
  end

  def variant_lookup
    @variant_lookup ||= ProductVariant.joins(:product)
                                      .where(products: { shopify_store_id: @store.id })
                                      .index_by(&:shopify_variant_id)
  end
end
```

- [ ] **Step 4 — Run to verify it passes**

Run: `bundle exec rspec spec/services/backfill_order_line_items_service_spec.rb`
Expected: PASS.

- [ ] **Step 5 — Commit**

```bash
git add app/services/backfill_order_line_items_service.rb spec/services/backfill_order_line_items_service_spec.rb
git commit -m "service: BackfillOrderLineItemsService (console-run, idempotent)"
```

---

## Task 11 — Routes + I18n base

**Files:**
- Modify: `config/routes.rb`
- Modify: `config/locales/en.yml`, `config/locales/zh-TW.yml`, `config/locales/zh-CN.yml`

- [ ] **Step 1 — Edit `config/routes.rb`**

Locate the existing `resources :shopify_stores ...` block. Replace it with:

```ruby
resources :shopify_stores, only: [:index, :show, :update, :destroy] do
  member do
    post :sync_products
  end
end

resources :products, only: [:index]

resources :product_variants, only: [:update] do
  collection do
    post :bulk_update
    get  :matching_ids
  end
end
```

- [ ] **Step 2 — Confirm routes load**

Run: `bin/rails routes | grep -E "products|sync_products|product_variants"`
Expected: see `products GET /products(.:format) products#index`, `product_variant PATCH ...`, `bulk_update_product_variants POST ...`, `matching_ids_product_variants GET ...`, `sync_products_shopify_store POST ...`.

- [ ] **Step 3 — Add I18n keys for English (`config/locales/en.yml`)**

Under the existing `en:` root (look for a sibling section such as `shopify_stores:`), add:

```yaml
en:
  products:
    title: "Products"
    no_store: "Connect a Shopify store first"
    store: "Store"
    per_page: "Per page"
    showing: "Showing %{from} – %{to} of %{total}"
    search_placeholder: "Search by product, variant, or SKU"
    columns:
      image: "Image"
      product: "Product"
      variant: "Variant"
      sku: "SKU"
      price: "Price"
      shopify_cost: "Shopify cost"
      unit_cost: "Our COGS"
      shopify_weight: "Shopify weight"
      weight: "Weight (g)"
  product_variants:
    updated: "Updated"
    bulk_no_selection: "Select at least one variant"
    bulk_no_fields: "Enter at least a COGS or weight value"
    bulk_updated: "Bulk updated %{count} SKUs"
  shopify_stores:
    sync_products: "Sync products"
    sync_products_enqueued: "Product sync queued"
    products_synced_at: "Products last synced"
    manage_products: "Manage products & costs"
  dashboard:
    gross_profit: "Gross profit"
    gross_margin: "Gross margin"
    net_profit: "Net profit"
    net_margin: "Net margin"
    cogs: "COGS"
    cogs_coverage: "COGS coverage"
```

- [ ] **Step 4 — Mirror keys in `config/locales/zh-TW.yml` and `config/locales/zh-CN.yml`**

Use parallel keys with translated values:

```yaml
zh-TW:
  products:
    title: "產品"
    no_store: "請先連結一個 Shopify Store"
    store: "店鋪"
    per_page: "每頁顯示"
    showing: "顯示 %{from} – %{to}，共 %{total} 筆"
    search_placeholder: "搜尋 product / variant / SKU"
    columns:
      image: "圖"
      product: "產品"
      variant: "規格"
      sku: "SKU"
      price: "售價"
      shopify_cost: "Shopify 成本"
      unit_cost: "我們的 COGS"
      shopify_weight: "Shopify 重量"
      weight: "重量 (g)"
  product_variants:
    updated: "已更新"
    bulk_no_selection: "請至少選擇一個 variant"
    bulk_no_fields: "請至少填入 COGS 或重量"
    bulk_updated: "已批量更新 %{count} 個 SKU"
  shopify_stores:
    sync_products: "同步產品"
    sync_products_enqueued: "產品同步已加入佇列"
    products_synced_at: "上次同步產品"
    manage_products: "管理產品與成本"
  dashboard:
    gross_profit: "毛利"
    gross_margin: "毛利率"
    net_profit: "淨利"
    net_margin: "淨利率"
    cogs: "成本"
    cogs_coverage: "COGS 覆蓋率"
```

For `zh-CN.yml`, use the simplified equivalents (e.g., `產品` → `产品`, `規格` → `规格`).

- [ ] **Step 5 — Commit**

```bash
git add config/routes.rb config/locales/en.yml config/locales/zh-TW.yml config/locales/zh-CN.yml
git commit -m "routes/i18n: products and product_variants endpoints + translations"
```

---

## Task 12 — `ProductsController#index` + request spec + view skeleton

**Files:**
- Create: `app/controllers/products_controller.rb`
- Create: `app/views/products/index.html.erb`
- Create: `app/views/product_variants/_row.html.erb`
- Create: `spec/requests/products_spec.rb`

- [ ] **Step 1 — Write the failing request spec**

`spec/requests/products_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Products", type: :request do
  let(:user) { create(:user) }
  let(:company) { user.companies.first }
  let(:store) { create(:shopify_store, user: user, company: company) }
  let(:product) { create(:product, shopify_store: store) }
  let!(:variant) { create(:product_variant, product: product, sku: "ABC-1", title: "Default") }

  before { sign_in user }

  it "returns 200 and renders the variant" do
    get products_path, params: { store_id: store.id }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("ABC-1")
  end

  it "filters by search" do
    create(:product_variant, product: product, sku: "OTHER-99")
    get products_path, params: { store_id: store.id, search: "ABC" }
    expect(response.body).to include("ABC-1")
    expect(response.body).not_to include("OTHER-99")
  end

  it "redirects when no store is connected" do
    other_user = create(:user)
    sign_out user
    sign_in other_user
    get products_path
    expect(response).to redirect_to(shopify_stores_path)
  end
end
```

Note: how `sign_in` is wired depends on the project's Devise / authentication test helpers. Mirror the pattern used by an existing request spec such as `spec/requests/orders_spec.rb` to match exact session setup.

- [ ] **Step 2 — Run to verify it fails**

Run: `bundle exec rspec spec/requests/products_spec.rb`
Expected: FAIL — `uninitialized constant ProductsController` or routing error.

- [ ] **Step 3 — Create the controller**

`app/controllers/products_controller.rb`:

```ruby
class ProductsController < AdminController
  PER_PAGE_DEFAULT = 50
  PER_PAGE_OPTIONS = [25, 50, 100, 200, 300, 500].freeze

  def index
    @search = params[:search].presence
    @page   = [params[:page].to_i, 1].max

    per_page = Integer(params[:per_page], exception: false)
    @per_page = PER_PAGE_OPTIONS.include?(per_page) ? per_page : PER_PAGE_DEFAULT

    @shopify_store = current_shopify_store || visible_shopify_stores.first
    return redirect_to(shopify_stores_path, alert: t("products.no_store")) unless @shopify_store

    variants = filtered_variants
    @total_count = variants.count
    @total_pages = (@total_count.to_f / @per_page).ceil
    @page = [@page, @total_pages].min if @total_pages > 0

    @variants = variants.order("products.title ASC, product_variants.title ASC")
                        .offset((@page - 1) * @per_page).limit(@per_page)
  end

  private

  def filtered_variants
    scope = ProductVariant.joins(:product)
                          .where(products: { shopify_store_id: @shopify_store.id })
                          .includes(:product)
    return scope unless @search
    q = "%#{ActiveRecord::Base.sanitize_sql_like(@search)}%"
    scope.where(
      "product_variants.sku ILIKE :q OR product_variants.title ILIKE :q OR products.title ILIKE :q",
      q: q
    )
  end
end
```

- [ ] **Step 4 — Create the row partial**

`app/views/product_variants/_row.html.erb`:

```erb
<tr id="<%= dom_id(variant) %>" class="border-b border-gray-200">
  <td class="px-2 py-2">
    <input type="checkbox"
           name="variant_ids[]"
           value="<%= variant.id %>"
           data-bulk-select-target="rowCheckbox"
           data-action="change->bulk-select#rowChanged">
  </td>
  <td class="px-2 py-2">
    <% if variant.product.image_url.present? %>
      <%= image_tag variant.product.image_url, class: "w-12 h-12 object-cover rounded" %>
    <% end %>
  </td>
  <td class="px-2 py-2 text-sm"><%= variant.product.title %></td>
  <td class="px-2 py-2 text-sm"><%= variant.title %></td>
  <td class="px-2 py-2 text-xs font-mono"><%= variant.sku.presence || "—" %></td>
  <td class="px-2 py-2 text-sm"><%= variant.price ? number_to_currency(variant.price, unit: "$") : "—" %></td>
  <td class="px-2 py-2 text-sm text-gray-500">
    <%= variant.shopify_cost ? number_with_precision(variant.shopify_cost, precision: 2) : "—" %>
  </td>
  <td class="px-2 py-2">
    <%= form_with model: variant, url: product_variant_path(variant), method: :patch,
                  data: { controller: "auto-submit" } do |f| %>
      <%= f.number_field :unit_cost, value: variant.unit_cost, step: 0.01, min: 0,
                         class: "w-24 border border-gray-300 rounded px-2 py-1 text-sm",
                         data: { action: "blur->auto-submit#submit" } %>
    <% end %>
  </td>
  <td class="px-2 py-2 text-sm text-gray-500">
    <%= variant.shopify_weight_grams ? "#{variant.shopify_weight_grams} g" : "—" %>
  </td>
  <td class="px-2 py-2">
    <%= form_with model: variant, url: product_variant_path(variant), method: :patch,
                  data: { controller: "auto-submit" } do |f| %>
      <%= f.number_field :weight_grams, value: variant.weight_grams, step: 0.001, min: 0.001,
                         class: "w-24 border border-gray-300 rounded px-2 py-1 text-sm",
                         data: { action: "blur->auto-submit#submit" } %>
    <% end %>
  </td>
</tr>
```

- [ ] **Step 5 — Create the index view (search + table; no bulk bar yet)**

`app/views/products/index.html.erb`:

```erb
<div class="max-w-7xl mx-auto">
  <h1 class="text-2xl font-semibold text-gray-900 mb-4"><%= t("products.title") %></h1>

  <%= form_with url: products_path, method: :get, local: true, class: "flex items-center gap-4 mb-4" do %>
    <input type="text" name="search" value="<%= @search %>"
           placeholder="<%= t("products.search_placeholder") %>"
           class="border border-gray-300 rounded px-3 py-1 w-80 text-sm">

    <% if visible_shopify_stores.count > 1 %>
      <label class="text-sm text-gray-600"><%= t("products.store") %></label>
      <select name="store_id"
              class="text-sm rounded-md border border-gray-300 bg-white py-1 pl-2 pr-7">
        <% visible_shopify_stores.each do |s| %>
          <option value="<%= s.id %>" <%= "selected" if @shopify_store&.id == s.id %>>
            <%= s.shop_domain %>
          </option>
        <% end %>
      </select>
    <% end %>

    <button type="submit" class="px-3 py-1 text-sm bg-blue-600 text-white rounded">Search</button>

    <% if @search.present? %>
      <%= link_to "Clear", products_path(store_id: @shopify_store&.id), class: "text-sm text-gray-500" %>
    <% end %>
  <% end %>

  <table class="w-full bg-white shadow-sm rounded-lg border border-gray-200">
    <thead class="bg-gray-50 text-left text-xs uppercase text-gray-500">
      <tr>
        <th class="px-2 py-2">
          <input type="checkbox" data-bulk-select-target="pageToggle" data-action="change->bulk-select#togglePage">
        </th>
        <th class="px-2 py-2"><%= t("products.columns.image") %></th>
        <th class="px-2 py-2"><%= t("products.columns.product") %></th>
        <th class="px-2 py-2"><%= t("products.columns.variant") %></th>
        <th class="px-2 py-2"><%= t("products.columns.sku") %></th>
        <th class="px-2 py-2"><%= t("products.columns.price") %></th>
        <th class="px-2 py-2"><%= t("products.columns.shopify_cost") %></th>
        <th class="px-2 py-2"><%= t("products.columns.unit_cost") %></th>
        <th class="px-2 py-2"><%= t("products.columns.shopify_weight") %></th>
        <th class="px-2 py-2"><%= t("products.columns.weight") %></th>
      </tr>
    </thead>
    <tbody>
      <% @variants.each do |variant| %>
        <%= render "product_variants/row", variant: variant %>
      <% end %>
    </tbody>
  </table>

  <nav class="flex items-center justify-between mt-4">
    <p class="text-sm text-gray-600">
      <%= t("products.showing", from: ((@page - 1) * @per_page) + 1, to: [@page * @per_page, @total_count].min, total: @total_count) %>
    </p>
    <div class="flex items-center gap-4">
      <div class="flex items-center gap-2">
        <label for="per_page" class="text-sm text-gray-600"><%= t("products.per_page") %></label>
        <select id="per_page" onchange="window.location.href = this.value"
                class="text-sm rounded-md border border-gray-300 bg-white py-1 pl-2 pr-7">
          <% ProductsController::PER_PAGE_OPTIONS.each do |opt| %>
            <option value="<%= products_path(request.query_parameters.merge(per_page: opt, page: 1)) %>"
                    <%= "selected" if opt == @per_page %>>
              <%= opt %>
            </option>
          <% end %>
        </select>
      </div>
      <% if @total_pages > 1 %>
        <div class="flex gap-1">
          <% if @page > 1 %>
            <%= link_to "←", products_path(request.query_parameters.merge(page: @page - 1)),
                class: "px-3 py-1 text-sm rounded-md border border-gray-300 bg-white" %>
          <% end %>
          <% if @page < @total_pages %>
            <%= link_to "→", products_path(request.query_parameters.merge(page: @page + 1)),
                class: "px-3 py-1 text-sm rounded-md border border-gray-300 bg-white" %>
          <% end %>
        </div>
      <% end %>
    </div>
  </nav>
</div>
```

- [ ] **Step 6 — Run to verify request spec passes**

Run: `bundle exec rspec spec/requests/products_spec.rb`
Expected: PASS.

- [ ] **Step 7 — Commit**

```bash
git add app/controllers/products_controller.rb app/views/products/ app/views/product_variants/_row.html.erb spec/requests/products_spec.rb
git commit -m "products: index page with search, pagination, store dropdown"
```

---

## Task 13 — `ProductVariantsController#update` + Turbo Stream + Stimulus auto-submit

**Files:**
- Create: `app/controllers/product_variants_controller.rb`
- Create: `app/views/product_variants/update.turbo_stream.erb`
- Create: `app/javascript/controllers/auto_submit_controller.js`
- Create: `spec/requests/product_variants_spec.rb`

- [ ] **Step 1 — Write the failing request spec**

`spec/requests/product_variants_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "ProductVariants", type: :request do
  let(:user) { create(:user) }
  let(:company) { user.companies.first }
  let(:store) { create(:shopify_store, user: user, company: company) }
  let(:product) { create(:product, shopify_store: store) }
  let!(:variant) { create(:product_variant, product: product) }

  before { sign_in user }

  describe "PATCH /product_variants/:id" do
    it "updates unit_cost" do
      patch product_variant_path(variant), params: { product_variant: { unit_cost: "12.50" } }
      expect(variant.reload.unit_cost).to eq(12.50)
    end

    it "updates weight_grams" do
      patch product_variant_path(variant), params: { product_variant: { weight_grams: "250.5" } }
      expect(variant.reload.weight_grams).to eq(250.5)
    end

    it "rejects negative unit_cost" do
      patch product_variant_path(variant), params: { product_variant: { unit_cost: "-1" } }
      expect(variant.reload.unit_cost).to be_nil
    end

    it "404s on cross-company variant" do
      other_store = create(:shopify_store)
      other_product = create(:product, shopify_store: other_store)
      other_variant = create(:product_variant, product: other_product)
      expect {
        patch product_variant_path(other_variant), params: { product_variant: { unit_cost: "5" } }
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
```

- [ ] **Step 2 — Run to verify it fails**

Run: `bundle exec rspec spec/requests/product_variants_spec.rb`
Expected: FAIL — controller not defined.

- [ ] **Step 3 — Create the controller**

`app/controllers/product_variants_controller.rb`:

```ruby
class ProductVariantsController < AdminController
  before_action :set_variant, only: :update

  def update
    if @variant.update(variant_params)
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to products_path, notice: t("product_variants.updated") }
      end
    else
      respond_to do |format|
        format.turbo_stream { render :update, status: :unprocessable_entity }
        format.html { redirect_to products_path, alert: @variant.errors.full_messages.join(", ") }
      end
    end
  end

  private

  def scoped_variants
    store_ids = visible_shopify_stores.pluck(:id)
    ProductVariant.joins(:product).where(products: { shopify_store_id: store_ids })
  end

  def set_variant
    @variant = scoped_variants.find(params[:id])
  end

  def variant_params
    params.require(:product_variant).permit(:unit_cost, :weight_grams)
  end
end
```

- [ ] **Step 4 — Create Turbo Stream view**

`app/views/product_variants/update.turbo_stream.erb`:

```erb
<%= turbo_stream.replace dom_id(@variant), partial: "product_variants/row", locals: { variant: @variant } %>
```

- [ ] **Step 5 — Create Stimulus controller**

`app/javascript/controllers/auto_submit_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }
}
```

- [ ] **Step 6 — Register the Stimulus controller**

If the project uses `app/javascript/controllers/index.js` with `eagerLoadControllersFrom`, registration is automatic. Otherwise verify there is a manual `application.register("auto-submit", AutoSubmitController)` line — if missing, add it next to the existing controller registrations.

- [ ] **Step 7 — Run to verify spec passes**

Run: `bundle exec rspec spec/requests/product_variants_spec.rb`
Expected: PASS.

- [ ] **Step 8 — Commit**

```bash
git add app/controllers/product_variants_controller.rb app/views/product_variants/update.turbo_stream.erb app/javascript/controllers/auto_submit_controller.js spec/requests/product_variants_spec.rb
git commit -m "product_variants: inline update via Turbo Stream + auto-submit Stimulus"
```

---

## Task 14 — Bulk update + `matching_ids` + bulk-select Stimulus controller

**Files:**
- Modify: `app/controllers/product_variants_controller.rb`
- Create: `app/javascript/controllers/bulk_select_controller.js`
- Modify: `app/views/products/index.html.erb`
- Modify: `spec/requests/product_variants_spec.rb`

- [ ] **Step 1 — Add failing examples**

Append to `spec/requests/product_variants_spec.rb` inside the existing `RSpec.describe` block:

```ruby
describe "POST /product_variants/bulk_update" do
  let!(:variant2) { create(:product_variant, product: product) }

  it "updates unit_cost across selected variants" do
    post bulk_update_product_variants_path,
         params: { variant_ids: [variant.id, variant2.id], unit_cost: "5.50" }
    expect(response).to redirect_to(products_path)
    expect(variant.reload.unit_cost).to eq(5.50)
    expect(variant2.reload.unit_cost).to eq(5.50)
  end

  it "updates only weight_grams when only that is sent" do
    post bulk_update_product_variants_path,
         params: { variant_ids: [variant.id], weight_grams: "300" }
    expect(variant.reload.weight_grams).to eq(300)
    expect(variant.unit_cost).to be_nil
  end

  it "alerts when no ids selected" do
    post bulk_update_product_variants_path, params: { unit_cost: "5" }
    follow_redirect!
    expect(response.body).to include(I18n.t("product_variants.bulk_no_selection"))
  end

  it "alerts when no fields provided" do
    post bulk_update_product_variants_path, params: { variant_ids: [variant.id] }
    follow_redirect!
    expect(response.body).to include(I18n.t("product_variants.bulk_no_fields"))
  end

  it "silently skips ids belonging to other companies" do
    other_store = create(:shopify_store)
    other_product = create(:product, shopify_store: other_store)
    other_variant = create(:product_variant, product: other_product, unit_cost: nil)

    post bulk_update_product_variants_path,
         params: { variant_ids: [variant.id, other_variant.id], unit_cost: "9.99" }

    expect(variant.reload.unit_cost).to eq(9.99)
    expect(other_variant.reload.unit_cost).to be_nil
  end
end

describe "GET /product_variants/matching_ids" do
  it "returns ids of variants matching search, scoped to store" do
    create(:product_variant, product: product, sku: "OTHER")
    get matching_ids_product_variants_path, params: { store_id: store.id, search: variant.sku }
    body = JSON.parse(response.body)
    expect(body["ids"]).to include(variant.id)
    expect(body["ids"].length).to eq(1)
  end

  it "returns [] when store_id is not visible" do
    other_store = create(:shopify_store)
    get matching_ids_product_variants_path, params: { store_id: other_store.id }
    body = JSON.parse(response.body)
    expect(body["ids"]).to eq([])
  end
end
```

- [ ] **Step 2 — Run to verify it fails**

Run: `bundle exec rspec spec/requests/product_variants_spec.rb -e "bulk_update"`
Expected: FAIL — route or action missing.

- [ ] **Step 3 — Extend `ProductVariantsController`**

Append these actions to `app/controllers/product_variants_controller.rb` (before the `private` keyword):

```ruby
def bulk_update
  ids = Array(params[:variant_ids]).map(&:to_s)
  return redirect_to(products_path, alert: t("product_variants.bulk_no_selection")) if ids.empty?

  updates = {}
  updates[:unit_cost]    = params[:unit_cost]    if params[:unit_cost].to_s.strip.present?
  updates[:weight_grams] = params[:weight_grams] if params[:weight_grams].to_s.strip.present?
  return redirect_to(products_path, alert: t("product_variants.bulk_no_fields")) if updates.empty?

  scope = scoped_variants.where(id: ids)
  count = 0
  ProductVariant.transaction do
    scope.find_each do |v|
      v.assign_attributes(updates)
      v.save!
      count += 1
    end
  end
  redirect_to products_path(request.query_parameters.slice(:store_id, :search, :per_page, :page)),
              notice: t("product_variants.bulk_updated", count: count)
rescue ActiveRecord::RecordInvalid => e
  redirect_to products_path, alert: e.record.errors.full_messages.join(", ")
end

def matching_ids
  store = visible_shopify_stores.find_by(id: params[:store_id])
  return render(json: { ids: [] }) unless store

  scope = ProductVariant.joins(:product).where(products: { shopify_store_id: store.id })
  if params[:search].present?
    pattern = "%#{ActiveRecord::Base.sanitize_sql_like(params[:search])}%"
    scope = scope.where(
      "product_variants.sku ILIKE :q OR product_variants.title ILIKE :q OR products.title ILIKE :q",
      q: pattern
    )
  end
  render json: { ids: scope.pluck(:id) }
end
```

- [ ] **Step 4 — Create bulk-select Stimulus controller**

`app/javascript/controllers/bulk_select_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["bar", "count", "rowCheckbox", "pageToggle"]
  static values  = {
    matchingUrl: String,
    storeId:     String,
    search:      String,
    total:       Number
  }

  connect() { this.refresh() }

  rowChanged() { this.refresh() }

  togglePage(event) {
    const checked = event.target.checked
    this.rowCheckboxTargets.forEach(cb => { cb.checked = checked })
    this.refresh()
  }

  clear() {
    this.rowCheckboxTargets.forEach(cb => { cb.checked = false })
    this.element.querySelectorAll('input[name="variant_ids[]"][type=hidden]').forEach(el => el.remove())
    this.refresh()
  }

  async selectAllMatching() {
    const url = `${this.matchingUrlValue}?store_id=${this.storeIdValue}&search=${encodeURIComponent(this.searchValue)}`
    const res = await fetch(url, { headers: { "Accept": "application/json" } })
    const { ids } = await res.json()
    this.clear()
    ids.forEach(id => {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "variant_ids[]"
      input.value = id
      this.element.appendChild(input)
    })
    this.refresh()
  }

  refresh() {
    const visible = this.rowCheckboxTargets.filter(cb => cb.checked).length
    const hidden  = this.element.querySelectorAll('input[name="variant_ids[]"][type=hidden]').length
    const total = visible + hidden
    if (this.hasCountTarget) this.countTarget.textContent = total
    if (this.hasBarTarget)   this.barTarget.classList.toggle("hidden", total === 0)
  }
}
```

- [ ] **Step 5 — Wrap products view in bulk form + bulk bar**

Modify `app/views/products/index.html.erb`. Replace the `<table>` block (and the `<nav>` block below it) with a `<form>` wrapper:

```erb
<%= form_with url: bulk_update_product_variants_path, method: :post, local: true,
              data: {
                controller: "bulk-select",
                bulk_select_matching_url_value: matching_ids_product_variants_path,
                bulk_select_store_id_value: @shopify_store.id,
                bulk_select_search_value: @search.to_s,
                bulk_select_total_value: @total_count
              } do |f| %>

  <div data-bulk-select-target="bar" class="hidden flex items-center gap-4 px-4 py-2 mb-2 bg-yellow-50 border border-yellow-200 rounded">
    <span><strong data-bulk-select-target="count">0</strong> selected</span>
    <button type="button" class="text-sm text-blue-600" data-action="click->bulk-select#selectAllMatching">
      Select all <%= @total_count %> matching
    </button>
    <button type="button" class="text-sm text-gray-500" data-action="click->bulk-select#clear">Clear</button>
    <input type="number" step="0.01" min="0" name="unit_cost" placeholder="<%= t("products.columns.unit_cost") %>"
           class="w-28 border border-gray-300 rounded px-2 py-1 text-sm">
    <input type="number" step="0.001" min="0.001" name="weight_grams" placeholder="<%= t("products.columns.weight") %>"
           class="w-28 border border-gray-300 rounded px-2 py-1 text-sm">
    <%= f.submit "Apply", class: "px-3 py-1 text-sm bg-blue-600 text-white rounded" %>
  </div>

  <%# the existing table from Task 12 goes here, unchanged %>
  <table class="w-full bg-white shadow-sm rounded-lg border border-gray-200">
    <!-- header + tbody from Task 12 -->
  </table>

  <%# the existing pagination nav from Task 12 goes here, unchanged %>
<% end %>
```

Move the existing `<table>` (with checkboxes and rows) and `<nav>` blocks **inside** this `<%= form_with ... do |f| %> ... <% end %>` wrapper. Do not duplicate them — relocate.

- [ ] **Step 6 — Run to verify request specs pass**

Run: `bundle exec rspec spec/requests/product_variants_spec.rb`
Expected: PASS.

- [ ] **Step 7 — Commit**

```bash
git add app/controllers/product_variants_controller.rb app/javascript/controllers/bulk_select_controller.js app/views/products/index.html.erb spec/requests/product_variants_spec.rb
git commit -m "product_variants: bulk_update, matching_ids, bulk-select Stimulus, bulk UI"
```

---

## Task 15 — `ShopifyStores#sync_products` + Shop detail page section

**Files:**
- Modify: `app/controllers/shopify_stores_controller.rb`
- Modify: `app/views/shopify_stores/show.html.erb`
- Modify: `spec/requests/shopify_stores_spec.rb`

- [ ] **Step 1 — Write the failing request spec**

Append to `spec/requests/shopify_stores_spec.rb` inside the existing top-level `RSpec.describe` block:

```ruby
describe "POST /shopify_stores/:id/sync_products" do
  let(:user) { create(:user) }
  let(:store) { create(:shopify_store, user: user, company: user.companies.first) }

  before { sign_in user }

  it "enqueues SyncShopifyProductsJob" do
    expect {
      post sync_products_shopify_store_path(store)
    }.to have_enqueued_job(SyncShopifyProductsJob).with(store.id)
  end

  it "redirects with notice" do
    post sync_products_shopify_store_path(store)
    expect(response).to redirect_to(shopify_store_path(store))
  end
end
```

- [ ] **Step 2 — Run to verify it fails**

Run: `bundle exec rspec spec/requests/shopify_stores_spec.rb -e "sync_products"`
Expected: FAIL — `No route matches` or action missing.

- [ ] **Step 3 — Modify the controller**

In `app/controllers/shopify_stores_controller.rb`, update the `before_action` line:

```ruby
before_action :set_shopify_store, only: [:show, :update, :destroy, :sync_products]
```

and append the action (above `private`):

```ruby
def sync_products
  SyncShopifyProductsJob.perform_later(@shopify_store.id)
  redirect_to shopify_store_path(@shopify_store), notice: t("shopify_stores.sync_products_enqueued")
end
```

- [ ] **Step 4 — Add UI section to `shopify_stores/show.html.erb`**

Locate a suitable spot inside the existing card layout (after the last `dl` div). Insert:

```erb
<div class="px-6 py-4 border-t border-gray-200">
  <h2 class="text-lg font-medium text-gray-900"><%= t("products.title") %></h2>
  <p class="mt-1 text-sm text-gray-500">
    <%= t("shopify_stores.products_synced_at") %>:
    <%= @shopify_store.products_synced_at ? l(@shopify_store.products_synced_at, format: :long) : "—" %>
  </p>
  <div class="mt-3 flex items-center gap-3">
    <%= button_to t("shopify_stores.sync_products"),
        sync_products_shopify_store_path(@shopify_store), method: :post,
        class: "inline-flex items-center gap-2 px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-md hover:bg-blue-700" %>
    <%= link_to t("shopify_stores.manage_products"),
        products_path(store_id: @shopify_store.id),
        class: "text-sm text-blue-600 hover:underline" %>
  </div>
</div>
```

- [ ] **Step 5 — Run to verify spec passes**

Run: `bundle exec rspec spec/requests/shopify_stores_spec.rb`
Expected: PASS.

- [ ] **Step 6 — Commit**

```bash
git add app/controllers/shopify_stores_controller.rb app/views/shopify_stores/show.html.erb spec/requests/shopify_stores_spec.rb
git commit -m "shopify_stores: sync_products button enqueues SyncShopifyProductsJob"
```

---

## Task 16 — System spec for products UI

**Files:**
- Create: `spec/system/products_spec.rb`

- [ ] **Step 1 — Write the system spec**

`spec/system/products_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Products UI", type: :system do
  let(:user) { create(:user) }
  let(:store) { create(:shopify_store, user: user, company: user.companies.first) }
  let(:product) { create(:product, shopify_store: store, title: "Paint Kit") }
  let!(:variant) { create(:product_variant, product: product, sku: "PK-BL", title: "Black/Large") }

  before do
    sign_in user
    driven_by(:rack_test)
  end

  it "shows variants on the products page" do
    visit products_path(store_id: store.id)
    expect(page).to have_content("Paint Kit")
    expect(page).to have_content("PK-BL")
    expect(page).to have_content("Black/Large")
  end

  it "filters by search" do
    create(:product_variant, product: product, sku: "OTHER-99")
    visit products_path(store_id: store.id, search: "PK-BL")
    expect(page).to have_content("PK-BL")
    expect(page).not_to have_content("OTHER-99")
  end

  it "respects per_page" do
    20.times { |i| create(:product_variant, product: product, sku: "X-#{i}") }
    visit products_path(store_id: store.id, per_page: 25)
    expect(page).to have_select("per_page", selected: "25")
  end
end
```

Note: full JS-driven flow (Stimulus blur-to-save, bulk select) requires `driven_by(:selenium_chrome_headless)` and Chromedriver — keep this simpler `:rack_test` flow for now to maintain coverage without browser setup. Add a JS-driven sibling spec only if the project already has system specs running selenium (`grep selenium spec/`).

- [ ] **Step 2 — Run to verify it passes**

Run: `bundle exec rspec spec/system/products_spec.rb`
Expected: PASS.

- [ ] **Step 3 — Commit**

```bash
git add spec/system/products_spec.rb
git commit -m "system spec: products page basic flow"
```

---

## Task 17 — `DashboardMetricsService` COGS aggregation

**Files:**
- Modify: `app/services/dashboard_metrics_service.rb`
- Modify: `spec/services/dashboard_metrics_service_spec.rb`

- [ ] **Step 1 — Add failing examples**

Append to `spec/services/dashboard_metrics_service_spec.rb` inside the existing top-level describe:

```ruby
describe "COGS / gross / net profit" do
  let(:user) { create(:user) }
  let(:company) { user.companies.first }
  let!(:store) { create(:shopify_store, user: user, company: company, timezone: "UTC") }
  let!(:customer) { create(:customer, shopify_store: store) }
  let!(:order) do
    create(:order, customer: customer, shopify_store: store,
                   total_price: 100, ordered_at: Date.current.beginning_of_day)
  end

  before do
    create(:order_line_item, order: order, quantity: 2, unit_cost_snapshot: 10) # 20
    create(:order_line_item, order: order, quantity: 1, unit_cost_snapshot: 5)  # 5
  end

  it "computes cogs over the date range" do
    result = described_class.new(company, range_key: "today").call
    expect(result[:current][:cogs]).to eq(25)
  end

  it "computes gross_profit and net_profit" do
    create(:shopify_daily_metric, shopify_store: store, date: Date.current,
                                  revenue: 100, orders_count: 1)
    result = described_class.new(company, range_key: "today").call
    expect(result[:current][:gross_profit]).to eq(75)   # 100 - 25
    expect(result[:current][:net_profit]).to eq(75)     # no ad spend
  end

  it "reports cogs_coverage_pct" do
    create(:order_line_item, order: order, quantity: 1, unit_cost_snapshot: nil)
    result = described_class.new(company, range_key: "today").call
    expect(result[:current][:cogs_coverage_pct]).to eq(66.7)
  end
end
```

- [ ] **Step 2 — Run to verify it fails**

Run: `bundle exec rspec spec/services/dashboard_metrics_service_spec.rb -e "COGS"`
Expected: FAIL — `cogs` key missing.

- [ ] **Step 3 — Modify `DashboardMetricsService#aggregate_metrics`**

Replace the body of `aggregate_metrics(range)` in `app/services/dashboard_metrics_service.rb`. The full method becomes:

```ruby
def aggregate_metrics(range)
  shopify = ShopifyDailyMetric.for_date_range(range)
  ad = AdDailyMetric.for_date_range(range)

  store_scope = @scope.respond_to?(:shopify_stores) ? @scope.shopify_stores : ShopifyStore.none
  ad_scope    = @scope.respond_to?(:ad_accounts)    ? @scope.ad_accounts    : AdAccount.none

  shopify = shopify.where(shopify_store_id: store_scope.select(:id))
  ad = ad.where(ad_account_id: ad_scope.select(:id))

  sessions = shopify.sum(:sessions)
  orders = shopify.sum(:orders_count)
  new_customer_orders = shopify.sum(:new_customer_orders_count)
  revenue = shopify.sum(:revenue)
  ad_spend = ad.sum(:spend)

  cogs, coverage = aggregate_cogs(store_scope, range)
  gross_profit = revenue - cogs
  net_profit = gross_profit - ad_spend

  {
    sessions: sessions, orders: orders, new_customer_orders: new_customer_orders,
    revenue: revenue, ad_spend: ad_spend,
    avg_order_value: orders > 0 ? (revenue / orders).round(2) : 0,
    conversion_rate: sessions > 0 ? (orders.to_f / sessions * 100).round(2) : 0,
    roas: ad_spend > 0 ? (revenue / ad_spend).round(2) : 0,
    cpa: (orders > 0 && ad_spend > 0) ? (ad_spend / orders).round(2) : nil,
    new_customer_cpa: (new_customer_orders > 0 && ad_spend > 0) ? (ad_spend / new_customer_orders).round(2) : nil,
    cogs: cogs,
    gross_profit: gross_profit,
    gross_margin_pct: revenue > 0 ? (gross_profit / revenue * 100).round(2) : nil,
    net_profit: net_profit,
    net_margin_pct: revenue > 0 ? (net_profit / revenue * 100).round(2) : nil,
    cogs_coverage_pct: coverage
  }
end

def aggregate_cogs(store_scope, range)
  total_cogs = BigDecimal("0")
  total_lines = 0
  covered_lines = 0

  store_scope.find_each do |store|
    tz = store.active_timezone
    start_utc = tz.local(range.first.year, range.first.month, range.first.day).utc
    end_utc   = tz.local(range.last.year,  range.last.month,  range.last.day).end_of_day.utc

    line_items = OrderLineItem.joins(:order)
                              .where(orders: { shopify_store_id: store.id,
                                               ordered_at: start_utc..end_utc })

    total_cogs    += line_items.sum("quantity * COALESCE(unit_cost_snapshot, 0)")
    total_lines   += line_items.count
    covered_lines += line_items.where.not(unit_cost_snapshot: nil).count
  end

  coverage = total_lines > 0 ? (covered_lines.to_f / total_lines * 100).round(1) : nil
  [total_cogs, coverage]
end
```

- [ ] **Step 4 — Run to verify spec passes**

Run: `bundle exec rspec spec/services/dashboard_metrics_service_spec.rb`
Expected: PASS.

- [ ] **Step 5 — Commit**

```bash
git add app/services/dashboard_metrics_service.rb spec/services/dashboard_metrics_service_spec.rb
git commit -m "dashboard: COGS / gross_profit / net_profit / coverage aggregation"
```

---

## Task 18 — Dashboard UI cards

**Files:**
- Modify: `app/views/dashboard/show.html.erb`

- [ ] **Step 1 — Add the three new cards**

Locate the grid in `app/views/dashboard/show.html.erb` around the existing metric cards (line ~50). After the ROAS or CPA card, add:

```erb
<%# Gross Profit %>
<%= render "dashboard/metric_card",
    title: t("dashboard.gross_profit"),
    value: number_to_currency(@metrics[:current][:gross_profit]),
    previous: @metrics[:previous][:gross_profit],
    current_raw: @metrics[:current][:gross_profit] %>

<%# Gross Margin %>
<%= render "dashboard/metric_card",
    title: t("dashboard.gross_margin"),
    value: @metrics[:current][:gross_margin_pct] ? "#{@metrics[:current][:gross_margin_pct]}%" : "—",
    previous: @metrics[:previous][:gross_margin_pct],
    current_raw: @metrics[:current][:gross_margin_pct] %>

<%# Net Profit %>
<%= render "dashboard/metric_card",
    title: t("dashboard.net_profit"),
    value: number_to_currency(@metrics[:current][:net_profit]),
    previous: @metrics[:previous][:net_profit],
    current_raw: @metrics[:current][:net_profit] %>
```

Below the grid (outside `<div class="grid ...">`), add the coverage note:

```erb
<% if @metrics[:current][:cogs_coverage_pct] && @metrics[:current][:cogs_coverage_pct] < 100 %>
  <p class="mt-2 text-xs text-gray-500">
    <%= t("dashboard.cogs_coverage") %>: <%= @metrics[:current][:cogs_coverage_pct] %>%
  </p>
<% end %>
```

- [ ] **Step 2 — Run dashboard request spec to make sure nothing breaks**

Run: `bundle exec rspec spec/requests/dashboard_spec.rb` (skip if no such spec exists) or `bundle exec rspec spec/system/`
Expected: PASS or no relevant spec.

- [ ] **Step 3 — Commit**

```bash
git add app/views/dashboard/show.html.erb
git commit -m "dashboard: gross profit / gross margin / net profit cards + coverage note"
```

---

## Task 19 — Full test suite + linters

- [ ] **Step 1 — Run RuboCop and auto-fix**

Run: `bin/rubocop -a`
Expected: clean exit (or only minor whitespace fixes applied).

- [ ] **Step 2 — Run the full spec suite**

Run: `bundle exec rspec`
Expected: PASS (entire suite, including pre-existing specs).

- [ ] **Step 3 — Run Brakeman**

Run: `bin/brakeman --no-pager`
Expected: no new warnings.

- [ ] **Step 4 — Commit any RuboCop auto-fixes**

```bash
git add -u
git diff --cached --quiet || git commit -m "style: rubocop autocorrect"
```

---

## Task 20 — Open PR to staging

- [ ] **Step 1 — Push branch**

```bash
git push -u origin feature/product-sync-and-cogs-design
```

- [ ] **Step 2 — Open PR via `gh`**

```bash
gh pr create --base staging --title "Shopify product sync + editable COGS / weight" --body "$(cat <<'EOF'
## Summary
- New `products`, `product_variants`, `order_line_items` tables (UUID PK)
- Per-store manual product sync from Shopify (`/products.json` + `/inventory_items.json`)
- Editable per-SKU `unit_cost` and `weight_grams`, inline + bulk update
- Order line items extracted with snapshotted `unit_cost` (frozen at sync time)
- `BackfillOrderLineItemsService` for historical data (console-run)
- Dashboard: gross profit, net profit, COGS coverage

## Test plan
- [ ] Connect a sandbox Shopify store; click "Sync products"; verify products / variants visible at `/products`
- [ ] Edit `unit_cost` on a variant; verify save on blur
- [ ] Bulk select via checkboxes, "Select all matching", apply unit_cost / weight
- [ ] Trigger an order sync; verify `OrderLineItem` rows are created with `unit_cost_snapshot`
- [ ] Run `BackfillOrderLineItemsService.new(store).call` in console on a store with historical orders; verify snapshots fill in
- [ ] Dashboard shows gross profit / net profit / margins / coverage

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3 — Return the PR URL**

Print the URL printed by `gh pr create` so the user can review.

---

## Self-Review

### Spec coverage
- Schema (3 tables + shopify_stores additions + orders index) → Task 1
- Models + validations + factories → Tasks 2, 3, 4, 5
- ShopifyService new methods → Task 6
- SyncShopifyProductsService → Task 7
- Job → Task 8
- SyncAllOrdersService line items → Task 9
- BackfillOrderLineItemsService → Task 10
- Routes + I18n → Task 11
- ProductsController + index view + row partial → Task 12
- ProductVariantsController#update + auto-submit Stimulus + Turbo Stream → Task 13
- Bulk update + matching_ids + bulk-select Stimulus + bulk bar → Task 14
- ShopifyStores#sync_products + shop detail UI → Task 15
- System spec → Task 16
- DashboardMetricsService COGS → Task 17
- Dashboard UI cards → Task 18
- Test/lint/PR → Tasks 19, 20

All spec sections are mapped.

### Type / signature consistency
- `unit_cost`, `unit_cost_snapshot`, `weight_grams`, `shopify_weight_grams` — names match across migration, model, factory, service, and view.
- `SyncShopifyProductsJob.perform_later(shopify_store_id)` — signature matches Task 8 spec, Task 15 controller, and the job class.
- `BackfillOrderLineItemsService.new(store).call` — used consistently in Task 10 spec, doc, and the service.
- `bulk_update_product_variants_path` / `matching_ids_product_variants_path` — generated from routes block in Task 11; referenced in Task 14 controller, view, and Stimulus controller.
- Stimulus controller names — `auto-submit` (Task 13), `bulk-select` (Task 14) — referenced via `data-controller` attribute consistently.

### Notes on potential gotchas during execution
- Devise / auth helpers for request specs: the plan assumes a `sign_in user` helper exists. The agent should mirror an existing request spec (e.g., `spec/requests/orders_spec.rb`) for the exact sign-in mechanics.
- `shoulda-matchers`: the plan uses `validate_numericality_of(...).is_greater_than(...).allow_nil` — confirm shoulda-matchers is in the Gemfile. If not, replace with explicit positive/negative test cases.
- ActiveJob test helper `have_enqueued_job` requires `ActiveJob::TestHelper` to be included in `rails_helper.rb` (usually present in `RSpec.configure { |c| c.include ActiveJob::TestHelper }`). Verify before relying on it.

