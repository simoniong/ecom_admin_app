# Variant Packaging Cost Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-variant `packaging_cost` field (CNY, default 0) that is inline- and bulk-editable on the Products page and is included in order COGS / margin calculations.

**Architecture:** New non-null decimal column on `product_variants` (default 0). The cost basis written to `order_line_items.unit_cost_snapshot` during sync/backfill becomes `(unit_cost + packaging_cost) / cost_fx_rate`, but only when `unit_cost` is present (preserving COGS-coverage semantics). UI mirrors the existing `unit_cost` column: inline `cell-edit` cell + bulk-bar input.

**Tech Stack:** Rails 8.1, PostgreSQL (UUID PKs), Hotwire/Turbo, Stimulus, RSpec + FactoryBot, Tailwind.

**Reference spec:** `docs/superpowers/specs/2026-06-02-variant-packaging-cost-design.md`

---

## File Structure

- **Modify** `db/migrate/` — new migration adding `packaging_cost`.
- **Modify** `app/models/product_variant.rb` — validation.
- **Modify** `app/services/sync_all_orders_service.rb` — cost basis.
- **Modify** `app/services/backfill_order_line_items_service.rb` — cost basis.
- **Modify** `app/controllers/product_variants_controller.rb` — strong params + bulk_update.
- **Modify** `config/locales/{en,zh-CN,zh-TW}.yml` — column label + bulk_no_fields text.
- **Modify** `app/views/products/index.html.erb` — header + bulk-bar input.
- **Modify** `app/views/product_variants/_row.html.erb` — inline-editable cell.
- **Modify** specs: `spec/models/product_variant_spec.rb`, `spec/requests/product_variants_spec.rb`, `spec/services/backfill_order_line_items_service_spec.rb`, `spec/services/sync_all_orders_service_spec.rb`, `spec/system/products_spec.rb`.

> **Toolchain note:** `rails`/`rspec`/`bundle` require `/home/simon/.rubies/ruby-3.4.7/bin` on PATH. Prefix commands with `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH`. SimpleCov may exit non-zero (code 2) on single-file spec runs — that is expected; judge pass/fail by the RSpec example summary, not the exit code.

---

## Task 1: Migration + model validation

**Files:**
- Create: `db/migrate/20260602120001_add_packaging_cost_to_product_variants.rb`
- Modify: `app/models/product_variant.rb:8`
- Test: `spec/models/product_variant_spec.rb`

- [ ] **Step 1: Write the failing model specs**

Add these examples inside the existing `describe "validations" do` block in `spec/models/product_variant_spec.rb` (after the `weight_grams` examples, before the block's closing `end` on line 57):

```ruby
    it "defaults packaging_cost to 0" do
      v = create(:product_variant)
      expect(v.packaging_cost).to eq(0)
    end

    it "accepts packaging_cost = 0" do
      v = build(:product_variant, packaging_cost: 0)
      expect(v).to be_valid
    end

    it "accepts a positive packaging_cost" do
      v = build(:product_variant, packaging_cost: 3.50)
      expect(v).to be_valid
    end

    it "rejects negative packaging_cost" do
      v = build(:product_variant, packaging_cost: -0.01)
      expect(v).not_to be_valid
    end
```

- [ ] **Step 2: Run the model specs to verify they fail**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/models/product_variant_spec.rb`
Expected: FAIL — `NoMethodError`/unknown attribute `packaging_cost` (column does not exist yet).

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260602120001_add_packaging_cost_to_product_variants.rb`:

```ruby
class AddPackagingCostToProductVariants < ActiveRecord::Migration[8.1]
  def change
    add_column :product_variants, :packaging_cost, :decimal,
               precision: 10, scale: 2, default: 0, null: false
  end
end
```

- [ ] **Step 4: Run the migration**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bin/rails db:migrate && PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bin/rails db:test:prepare`
Expected: migration runs; `db/schema.rb` now shows `t.decimal "packaging_cost", precision: 10, scale: 2, default: "0.0", null: false` on `product_variants`.

- [ ] **Step 5: Add the model validation**

In `app/models/product_variant.rb`, add a validation line directly after the `weight_grams` validation (currently line 8):

```ruby
  validates :packaging_cost, numericality: { greater_than_or_equal_to: 0 }
```

The validations block should read:

```ruby
  validates :shopify_variant_id, presence: true
  validates :unit_cost,      numericality: { greater_than_or_equal_to: 0, allow_nil: true }
  validates :weight_grams,   numericality: { greater_than: 0,            allow_nil: true }
  validates :packaging_cost, numericality: { greater_than_or_equal_to: 0 }
```

- [ ] **Step 6: Run the model specs to verify they pass**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/models/product_variant_spec.rb`
Expected: PASS (all examples green in the RSpec summary).

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260602120001_add_packaging_cost_to_product_variants.rb db/schema.rb app/models/product_variant.rb spec/models/product_variant_spec.rb
git commit -m "feat: add packaging_cost column and validation to product_variants"
```

---

## Task 2: Include packaging_cost in COGS snapshot (backfill service)

**Files:**
- Modify: `app/services/backfill_order_line_items_service.rb:34-36`
- Test: `spec/services/backfill_order_line_items_service_spec.rb`

- [ ] **Step 1: Write the failing service specs**

In `spec/services/backfill_order_line_items_service_spec.rb`, update the existing snapshot example and add two new ones. Replace the example at lines 29-35 ("snapshots unit_cost converted from CNY to store currency") with the version below, and add the two examples after it:

```ruby
  it "snapshots unit_cost converted from CNY to store currency" do
    described_class.new(store).call
    li = order.order_line_items.find_by(shopify_line_item_id: 6001)
    # 72 CNY / 7.2 = 10.00 USD
    expect(li.unit_cost_snapshot).to eq(10.00)
    expect(li.product_variant).to eq(variant)
  end

  it "includes packaging_cost in the snapshot cost basis" do
    variant.update!(packaging_cost: 7.20)
    described_class.new(store).call
    li = order.order_line_items.find_by(shopify_line_item_id: 6001)
    # (72 + 7.2) CNY / 7.2 = 11.00 USD
    expect(li.unit_cost_snapshot).to eq(11.00)
  end

  it "leaves snapshot nil when unit_cost is nil even if packaging_cost is set" do
    variant.update!(unit_cost: nil, packaging_cost: 5.00)
    described_class.new(store).call
    li = order.order_line_items.find_by(shopify_line_item_id: 6001)
    expect(li.unit_cost_snapshot).to be_nil
  end
```

- [ ] **Step 2: Run the service specs to verify the new ones fail**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/backfill_order_line_items_service_spec.rb`
Expected: the "includes packaging_cost" example FAILS (got 10.00, expected 11.00). The "leaves snapshot nil" example already passes (current gate is `unit_cost.present?`).

- [ ] **Step 3: Update the cost basis in the service**

In `app/services/backfill_order_line_items_service.rb`, replace lines 34-38:

```ruby
    if line_item.unit_cost_snapshot.nil? && variant&.unit_cost.present? && @store.cost_fx_rate&.positive?
      # variant.unit_cost is in CNY; divide by CNY-per-store-currency rate.
      line_item.unit_cost_snapshot = variant.unit_cost / @store.cost_fx_rate
      @snapshotted += 1
    end
```

with:

```ruby
    if line_item.unit_cost_snapshot.nil? && variant&.unit_cost.present? && @store.cost_fx_rate&.positive?
      # unit_cost + packaging_cost are in CNY; divide by CNY-per-store-currency rate.
      line_item.unit_cost_snapshot =
        (variant.unit_cost + variant.packaging_cost) / @store.cost_fx_rate
      @snapshotted += 1
    end
```

- [ ] **Step 4: Run the service specs to verify they pass**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/backfill_order_line_items_service_spec.rb`
Expected: PASS (all green).

- [ ] **Step 5: Commit**

```bash
git add app/services/backfill_order_line_items_service.rb spec/services/backfill_order_line_items_service_spec.rb
git commit -m "feat: include packaging_cost in backfill COGS snapshot"
```

---

## Task 3: Include packaging_cost in COGS snapshot (sync service)

**Files:**
- Modify: `app/services/sync_all_orders_service.rb:139-143`
- Test: `spec/services/sync_all_orders_service_spec.rb`

- [ ] **Step 1: Write the failing service specs**

In `spec/services/sync_all_orders_service_spec.rb`, inside the `describe "line item sync"` block, add two examples directly after the existing "snapshots unit_cost from matching variant" example (which ends at line 408):

```ruby
    it "includes packaging_cost in the snapshot cost basis" do
      variant_a.update!(packaging_cost: 9.00)
      service.call
      li = OrderLineItem.find_by(shopify_line_item_id: 6001)
      # (90 + 9) CNY / 7.2 = 13.75 USD
      expect(li.unit_cost_snapshot).to eq(13.75)
    end

    it "leaves snapshot nil when unit_cost is nil even if packaging_cost is set" do
      variant_a.update!(unit_cost: nil, packaging_cost: 5.00)
      service.call
      li = OrderLineItem.find_by(shopify_line_item_id: 6001)
      expect(li.unit_cost_snapshot).to be_nil
    end
```

- [ ] **Step 2: Run the service specs to verify the new one fails**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/sync_all_orders_service_spec.rb`
Expected: the "includes packaging_cost" example FAILS (got 12.50, expected 13.75). The "leaves snapshot nil" example already passes.

- [ ] **Step 3: Update the cost basis in the service**

In `app/services/sync_all_orders_service.rb`, replace lines 139-143:

```ruby
      if line_item.unit_cost_snapshot.nil? && variant&.unit_cost.present? && @store.cost_fx_rate&.positive?
        # variant.unit_cost is in CNY; divide by CNY-per-store-currency rate.
        # Snapshot is always in store currency (matches shop_money above).
        line_item.unit_cost_snapshot = variant.unit_cost / @store.cost_fx_rate
      end
```

with:

```ruby
      if line_item.unit_cost_snapshot.nil? && variant&.unit_cost.present? && @store.cost_fx_rate&.positive?
        # unit_cost + packaging_cost are in CNY; divide by CNY-per-store-currency rate.
        # Snapshot is always in store currency (matches shop_money above).
        line_item.unit_cost_snapshot =
          (variant.unit_cost + variant.packaging_cost) / @store.cost_fx_rate
      end
```

- [ ] **Step 4: Run the service specs to verify they pass**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/services/sync_all_orders_service_spec.rb`
Expected: PASS (all green).

- [ ] **Step 5: Commit**

```bash
git add app/services/sync_all_orders_service.rb spec/services/sync_all_orders_service_spec.rb
git commit -m "feat: include packaging_cost in order sync COGS snapshot"
```

---

## Task 4: Controller — strong params + bulk_update

**Files:**
- Modify: `app/controllers/product_variants_controller.rb:23-25,69`
- Test: `spec/requests/product_variants_spec.rb`

- [ ] **Step 1: Write the failing request specs**

In `spec/requests/product_variants_spec.rb`:

(a) Inside `describe "PATCH /product_variants/:id"`, add after the "updates weight_grams" example (line 20):

```ruby
    it "updates packaging_cost" do
      patch product_variant_path(id: variant.id), params: { product_variant: { packaging_cost: "2.75" } }
      expect(variant.reload.packaging_cost).to eq(2.75)
    end
```

(b) Inside `describe "POST /product_variants/bulk_update"`, add after the "updates only weight_grams" example (line 71):

```ruby
    it "updates packaging_cost across selected variants" do
      post bulk_update_product_variants_path,
           params: { variant_ids: [ variant.id, variant2.id ], packaging_cost: "1.20" }
      expect(variant.reload.packaging_cost).to eq(1.20)
      expect(variant2.reload.packaging_cost).to eq(1.20)
    end

    it "treats packaging_cost alone as a provided field (not bulk_no_fields)" do
      post bulk_update_product_variants_path,
           params: { variant_ids: [ variant.id ], packaging_cost: "0.50" }
      expect(variant.reload.packaging_cost).to eq(0.50)
    end
```

- [ ] **Step 2: Run the request specs to verify they fail**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/requests/product_variants_spec.rb`
Expected: FAIL — packaging_cost stays 0 (not permitted / not handled in bulk_update).

- [ ] **Step 3: Permit packaging_cost in strong params**

In `app/controllers/product_variants_controller.rb`, change `variant_params` (line 69) from:

```ruby
    params.require(:product_variant).permit(:unit_cost, :weight_grams)
```

to:

```ruby
    params.require(:product_variant).permit(:unit_cost, :weight_grams, :packaging_cost)
```

- [ ] **Step 4: Handle packaging_cost in bulk_update**

In `app/controllers/product_variants_controller.rb`, in the `bulk_update` action add a line after the `weight_grams` assignment (currently line 24), so the block reads:

```ruby
    updates = {}
    updates[:unit_cost]      = params[:unit_cost]      if params[:unit_cost].to_s.strip.present?
    updates[:weight_grams]   = params[:weight_grams]   if params[:weight_grams].to_s.strip.present?
    updates[:packaging_cost] = params[:packaging_cost] if params[:packaging_cost].to_s.strip.present?
    return redirect_to(products_path, alert: t("product_variants.bulk_no_fields")) if updates.empty?
```

- [ ] **Step 5: Run the request specs to verify they pass**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/requests/product_variants_spec.rb`
Expected: PASS (all green).

- [ ] **Step 6: Commit**

```bash
git add app/controllers/product_variants_controller.rb spec/requests/product_variants_spec.rb
git commit -m "feat: permit and bulk-update packaging_cost on variants"
```

---

## Task 5: Locale strings

**Files:**
- Modify: `config/locales/en.yml`
- Modify: `config/locales/zh-CN.yml`
- Modify: `config/locales/zh-TW.yml`

- [ ] **Step 1: Add the column label and update bulk_no_fields (en)**

In `config/locales/en.yml`, under `products.columns`, add `packaging_cost` between `unit_cost` and `weight`:

```yaml
      unit_cost: "Our COGS"
      packaging_cost: "Packaging Cost"
      weight: "Weight (g)"
```

And change `product_variants.bulk_no_fields` to:

```yaml
    bulk_no_fields: "Enter at least a COGS, packaging, or weight value"
```

- [ ] **Step 2: Add the column label and update bulk_no_fields (zh-CN)**

In `config/locales/zh-CN.yml`, under `products.columns`:

```yaml
      unit_cost: "我们的 COGS"
      packaging_cost: "包材成本"
      weight: "重量 (g)"
```

And change `product_variants.bulk_no_fields` to:

```yaml
    bulk_no_fields: "请至少填入 COGS、包材成本或重量"
```

- [ ] **Step 3: Add the column label and update bulk_no_fields (zh-TW)**

In `config/locales/zh-TW.yml`, under `products.columns`:

```yaml
      unit_cost: "我們的 COGS"
      packaging_cost: "包材成本"
      weight: "重量 (g)"
```

And change `product_variants.bulk_no_fields` to:

```yaml
    bulk_no_fields: "請至少填入 COGS、包材成本或重量"
```

- [ ] **Step 4: Verify locales load**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bin/rails runner "%w[en zh-CN zh-TW].each { |l| puts I18n.t('products.columns.packaging_cost', locale: l) }"`
Expected: prints `Packaging Cost`, `包材成本`, `包材成本` (no `translation missing`).

- [ ] **Step 5: Commit**

```bash
git add config/locales/en.yml config/locales/zh-CN.yml config/locales/zh-TW.yml
git commit -m "feat: add packaging_cost locale strings"
```

---

## Task 6: Views — header, bulk-bar input, inline cell

**Files:**
- Modify: `app/views/products/index.html.erb:71,95-96`
- Modify: `app/views/product_variants/_row.html.erb:34` (insert new cell after unit_cost cell)
- Test: `spec/system/products_spec.rb`

- [ ] **Step 1: Write the failing system spec**

In `spec/system/products_spec.rb`, add this example before the final closing `end` (after the per_page example):

```ruby
  it "renders the packaging cost column with a default of 0.00" do
    variant.update!(packaging_cost: 0)
    visit products_path(store_id: store.id)
    expect(page).to have_content("Packaging Cost")
    expect(page).to have_content("0.00")
  end
```

- [ ] **Step 2: Run the system spec to verify it fails**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/system/products_spec.rb -e "packaging cost column"`
Expected: FAIL — "Packaging Cost" header not present.

- [ ] **Step 3: Add the table header**

In `app/views/products/index.html.erb`, add a `<th>` between the `unit_cost` header (line 95) and the `weight` header (line 96):

```erb
          <th class="px-2 py-2"><%= t("products.columns.unit_cost") %> (CNY)</th>
          <th class="px-2 py-2"><%= t("products.columns.packaging_cost") %> (CNY)</th>
          <th class="px-2 py-2"><%= t("products.columns.weight") %></th>
```

- [ ] **Step 4: Add the bulk-bar input**

In `app/views/products/index.html.erb`, between the `unit_cost` bulk label (ends line 70) and the `weight` bulk label (starts line 71), insert:

```erb
      <label class="text-sm text-gray-600">
        <%= t("products.columns.packaging_cost") %>
        <input type="number" step="0.01" min="0" name="packaging_cost"
               placeholder="—"
               class="w-24 border border-gray-300 rounded px-2 py-1 text-sm ml-1">
      </label>
```

- [ ] **Step 5: Add the inline-editable cell**

In `app/views/product_variants/_row.html.erb`, insert a new `<td>` between the `unit_cost` cell (closes at line 34, `</td>`) and the `weight_grams` cell (opens at line 35):

```erb
  <td class="px-2 py-2"
      data-controller="cell-edit"
      data-cell-edit-url-value="<%= product_variant_path(id: variant.id) %>"
      data-cell-edit-field-value="packaging_cost"
      data-cell-edit-step-value="0.01"
      data-cell-edit-min-value="0">
    <span data-cell-edit-target="display"
          role="button"
          tabindex="0"
          aria-label="<%= t("product_variants.cell_edit_aria") %>"
          data-action="click->cell-edit#startEdit keydown.enter->cell-edit#startEdit keydown.space->cell-edit#startEdit"
          class="cursor-pointer hover:bg-gray-100 focus:bg-gray-100 focus:outline-none focus:ring-2 focus:ring-blue-300 px-2 py-1 rounded inline-block min-w-[64px] text-sm border border-dashed border-transparent hover:border-gray-300">
      <%= number_with_precision(variant.packaging_cost, precision: 2) %>
    </span>
  </td>
```

- [ ] **Step 6: Run the system spec to verify it passes**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec spec/system/products_spec.rb`
Expected: PASS (all green).

- [ ] **Step 7: Commit**

```bash
git add app/views/products/index.html.erb app/views/product_variants/_row.html.erb spec/system/products_spec.rb
git commit -m "feat: add packaging_cost column, bulk input, and inline edit cell"
```

---

## Task 7: Full suite + lint

**Files:** none (verification only)

- [ ] **Step 1: Run the full spec suite**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bundle exec rspec`
Expected: all examples pass; coverage stays ≥ 95% (CI gate).

- [ ] **Step 2: Run RuboCop**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bin/rubocop`
Expected: no offenses. If alignment offenses appear on the new validation/locale lines, run `bin/rubocop -a` and re-run the suite.

- [ ] **Step 3: Run Brakeman**

Run: `PATH=/home/simon/.rubies/ruby-3.4.7/bin:$PATH bin/brakeman --no-pager`
Expected: no new warnings.

- [ ] **Step 4: Commit any lint fixups (if needed)**

```bash
git add -A
git commit -m "chore: rubocop autocorrect for packaging_cost"
```

---

## Notes & Out-of-Scope (from spec)

- Snapshot changes affect **future** sync/backfill only; existing `unit_cost_snapshot` values are not retroactively recomputed (same as current `unit_cost` behavior).
- `sync_shopify_products_service#upsert_variant` never assigns `unit_cost`/`weight_grams`/`packaging_cost`, so Shopify sync will not overwrite admin-edited packaging cost. No change needed there.
- `shipping_cost_calculator` (shipping, not COGS) is intentionally untouched.
- This is a feature branch (`feature/variant-packaging-cost`). Open a PR to `staging` after Task 7.
