# Variant 包材成本 (packaging_cost) — Design

Date: 2026-06-02
Status: Approved

## 背景

Product 模塊(`products/index`)目前讓使用者管理每個 variant 的成本資料:
- `unit_cost`(我們的 COGS,以 CNY 計)— nullable,沒填顯示 "—"
- `weight_grams`(重量)

兩者皆可**行內編輯**(`cell-edit` Stimulus controller)與**批量編輯**(黃色 bar → `ProductVariantsController#bulk_update`)。

`unit_cost` 透過 store 的 `cost_fx_rate`(CNY → 店鋪幣別)換算後,於 sync/backfill 時寫入
`order_line_items.unit_cost_snapshot`,進而算入訂單 COGS 與 dashboard 毛利。

## 需求

每個 variant 新增一個「包材成本」欄位(盒子等耗材),要求:
1. 可批量編輯(比照 cost、weight)。
2. 預設為 0(沒有填寫時)。
3. 與 `unit_cost` 一致:幣別 CNY、精度 2 位小數。
4. 算進訂單成本與 dashboard 毛利。

## 設計

### 1. 資料模型

Migration:`product_variants` 新增欄位
```ruby
add_column :product_variants, :packaging_cost, :decimal, precision: 10, scale: 2,
           default: 0, null: false
```
- `default: 0, null: false`:既有資料自動回填 0,符合「沒填預設 0」。
- 與 nullable 的 `unit_cost` 不同,`packaging_cost` 永遠有值,顯示為 `0.00`。

Model 驗證(`ProductVariant`):
```ruby
validates :packaging_cost, numericality: { greater_than_or_equal_to: 0 }
```
非 nullable,故不需 `allow_nil`。

### 2. COGS / 毛利整合

成本基準改為:**單件成本 CNY = `unit_cost + packaging_cost`**,
再除以 `cost_fx_rate` 換算成店鋪幣別寫入 `unit_cost_snapshot`。

**關鍵語意決定**:snapshot 仍**只在 `unit_cost.present?` 時**才寫入。
`unit_cost` 為 nil 代表「商品成本未知」,COGS 覆蓋率(dashboard 以
`unit_cost_snapshot: nil` 判斷未覆蓋)不應因僅填了包材成本而誤判為「已覆蓋」。
當 `unit_cost` 有值時,才加上 `packaging_cost` 一起換算。

修改兩處(邏輯相同):
- `app/services/sync_all_orders_service.rb`(約 L139-142)
- `app/services/backfill_order_line_items_service.rb`(約 L34-36)

由:
```ruby
line_item.unit_cost_snapshot = variant.unit_cost / @store.cost_fx_rate
```
改為:
```ruby
line_item.unit_cost_snapshot =
  (variant.unit_cost + variant.packaging_cost) / @store.cost_fx_rate
```

注意事項:
- 與現況一致,只影響**之後**的 sync/backfill,不回溯重算已存在的 snapshot
  (編輯 `unit_cost` 現在也是如此)。
- 不改動 `shipping_cost_calculator`(運費,與 COGS 無關)。
- `sync_shopify_products_service#upsert_variant` 不指派 `unit_cost`/`weight_grams`,
  同理不會碰 `packaging_cost`,Shopify 同步天然不覆蓋使用者編輯值。

### 3. UI(`products/index`)

- 表格在「Our COGS (CNY)」欄後新增一欄「包材成本 (CNY)」。
- 行內可編輯:沿用 `cell-edit` controller,`field=packaging_cost`,`step=0.01`,`min=0`;
  顯示 `number_with_precision(variant.packaging_cost, precision: 2)`(永遠有值,如 `0.00`)。
- 黃色批量 bar 新增一個 `packaging_cost` 數字輸入框(`step=0.01 min=0`)。
- `ProductVariantsController`:
  - `variant_params` permit `:packaging_cost`。
  - `bulk_update`:比照 `unit_cost`/`weight_grams`,
    `updates[:packaging_cost] = params[:packaging_cost] if params[:packaging_cost].to_s.strip.present?`。
- Locale(`en` / `zh-CN` / `zh-TW`):
  - 新增 `products.columns.packaging_cost`。
  - 更新 `product_variants.bulk_no_fields` 提示文字,含包材成本。

### 4. 測試(維持 95%+ 覆蓋)

- **Model spec**:`packaging_cost` 預設 0;拒絕負數;接受 0 與正數。
- **Request spec**:
  - 單筆 `update` 寫入 `packaging_cost`(turbo_stream + html)。
  - `bulk_update` 套用 `packaging_cost` 至選取的 variants。
  - `bulk_update` 只填 packaging 也算有效欄位(不再 `bulk_no_fields`)。
- **Service spec**(sync + backfill):
  - snapshot = `(unit_cost + packaging_cost) / fx`。
  - `unit_cost` 為 nil 時,即使有 `packaging_cost` 也不寫 snapshot。
- **System spec**:行內編輯包材成本欄;批量編輯包材成本欄。

## 範圍外(YAGNI)

- 不回溯重算已存在訂單的 snapshot。
- 不在 Shopify 同步包材成本。
- 不調整運費計算。
