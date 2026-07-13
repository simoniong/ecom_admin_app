# Net Revenue Breakdown — Design

日期：2026-07-13
分支：`feature/net-revenue-breakdown`

## 問題背景

Dashboard 上的 Revenue 不等於公司實際入袋的錢。Shopify 會扣掉金流交易手續費，訂單裡的稅是代收代付、要上繳政府，退款也要從收入扣除。使用者希望 dashboard 明確拆解出這些扣項，並顯示一個「實收金額（Net Revenue）」指標。

### 現況重點（設計前的關鍵發現）

- Dashboard 的 Revenue 來自 `ShopifyDailyMetric.revenue`，其現有定義為
  `revenue = gross_revenue − refunds_total`，其中
  `gross_revenue = subtotal + shipping + tax`（見 `ShopifyAnalyticsService#sync_date`）。
  也就是說**現有 Revenue 已含稅、含運費，且已扣過退款**。
- `revenue` 欄位是下游多個指標的基礎（`DashboardMetricsService`：`gross_profit`、`avg_order_value`、
  `roas`、`gross_margin_pct`、`net_profit`、`net_margin_pct`）。**本設計不改變 `revenue` 的定義**，
  以免連鎖影響既有指標。
- **交易手續費目前完全沒有被同步**。Shopify REST `/orders.json`（現用同步來源）不含金流手續費；
  精確手續費需另外呼叫 Shopify Payments balance transactions API。
- 交易手續費**僅涵蓋 Shopify Payments 訂單**；PayPal／其他金流的訂單不會出現在 balance transactions，
  該部分手續費無法取得。使用者確認幾乎全部使用 Shopify Payments，影響很小，但仍需在 UI 標註。

## 決策摘要（已與使用者確認）

- 扣項：**交易手續費、退款、稅**，各自為獨立指標並在 dashboard 呈現。
- 基準採 **Gross 模型**：顯示 Gross Revenue → 逐項扣除 → Net Revenue，避免退款被重複扣除。
- 交易手續費採 **Shopify Payments balance transactions API 精確值**（非固定費率估算）。
- **一個 PR 一次做到好**（含手續費），不分階段。
- 幾乎全部 Shopify Payments，手續費覆蓋率高；不做完整覆蓋率統計功能，只加一行說明字。

## 核心公式

```
Net Revenue = Gross Revenue − Refunds − Tax(net) − Transaction Fees
```

各項定義：

| 指標 | 定義 |
|------|------|
| `gross_revenue` | subtotal（商品小計）+ shipping（運費）+ tax（收到的稅），退款前的總收 |
| `refunds` | 退款總額 = 退款商品 + 退款運費 + 退款稅 − order adjustments（沿用現有 refund 計算邏輯） |
| `total_tax`（淨稅） | 收到的稅 − 退掉的稅（= 實際要上繳政府的稅） |
| `transaction_fees` | Shopify Payments 每筆真實手續費，依 balance transaction 的 `processed_at` 日期歸屬 |
| `net_revenue` | 上述公式結果，公司實際留下的錢 |

### 數學一致性驗證

令 `sub_c`/`ship_c`/`tax_c` 為收到的商品/運費/稅，`ref_sub`/`ref_ship`/`ref_tax` 為退掉的部分，
`adj` 為 order adjustments，`fees` 為手續費。

```
gross_revenue = sub_c + ship_c + tax_c
refunds       = ref_sub + ref_ship + ref_tax − adj      # 沿用現有計算
total_tax     = tax_c − ref_tax                          # 淨稅
net_revenue   = gross_revenue − refunds − total_tax − fees
              = (sub_c + ship_c + tax_c)
                − (ref_sub + ref_ship + ref_tax − adj)
                − (tax_c − ref_tax)
                − fees
              = (sub_c − ref_sub) + (ship_c − ref_ship) + adj − fees
```

`tax_c` 與 `ref_tax` 完全抵銷 → Net Revenue = 淨商品 + 淨運費 + 調整 − 手續費，
稅這條 pass-through 被正確消掉，結果就是實際入袋金額。此一致性成立的前提是
`total_tax` 存的是**淨稅**（收到的稅 − 退掉的稅），設計採此定義。

## 架構與元件

### 1. Migration：`shopify_daily_metrics` 加欄位

新增四個欄位（皆 `decimal precision: 12, scale: 2, default: 0, null: false`）：

- `gross_revenue`
- `refunds`
- `total_tax`
- `transaction_fees`

`net_revenue` **不落地為欄位**，於 `DashboardMetricsService` 聚合時即時計算，避免與四個扣項不同步。
現有 `revenue` 欄位保留、定義不變。

Backfill：既有列的新欄位預設 0；正確歷史值由既有的 `BackfillShopifyMetricsJob`（重跑 `sync_date`）補齊。

### 2. `ShopifyAnalyticsService`（改寫 `sync_date` 與 GraphQL 抽取）

- 訂單抓取（`fetch_orders_via_graphql`）：目前把 `subtotal + shipping + tax` 合併回傳為單一
  `gross_revenue`。改為**同時**回傳 `gross_revenue` 與其中的 `tax_charged`（`totalTaxSet` 的加總）。
- 退款抓取（`fetch_refunds_via_graphql` / `fetch_refunds_for_status`）：目前回傳單一 `refunds_total`。
  改為**同時**回傳 `refunds_total` 與其中的 `tax_refunded`
  （`refundLineItems.totalTaxSet` + `refundShippingLines.taxAmountSet` 的加總）。
- 新增私有 method `fetch_transaction_fees(date)`：呼叫 Shopify Payments balance transactions
  （見元件 3），回傳當日手續費總額。
- `sync_date` 寫入：
  - `revenue`（維持 `gross_revenue − refunds_total`，不變）
  - `gross_revenue = gross_revenue`
  - `refunds = refunds_total`
  - `total_tax = tax_charged − tax_refunded`
  - `transaction_fees = fetch_transaction_fees(date)`

### 3. Shopify Payments 手續費取得

- 沿用現有 GraphQL client（`ShopifyAPI::Clients::Graphql::Admin`，與 `ShopifyAnalyticsService`
  build 方式一致），查詢 `shopifyPaymentsAccount { balanceTransactions(...) }`，取每筆 `fee`（shop money）
  與 `transactionDate`／`processedAt`，並依日期區間過濾與分頁累加（沿用現有 cursor 分頁樣式）。
  - 若店家未啟用 Shopify Payments，`shopifyPaymentsAccount` 為 `null` → 手續費視為 0，不報錯。
- 日期歸屬：以 balance transaction 的處理日期歸入當日 `transaction_fees`（cash-flow 觀點）。
  此與 gross（依 order created_at）之間存在小幅日期錯位，屬已知近似，於 spec 標註。
- 手續費為費用（正值扣項）；balance transactions 中 fee 一律以正值累加。

### 4. `DashboardMetricsService#aggregate_metrics`

- 新增聚合：`gross_revenue = shopify.sum(:gross_revenue)`、`refunds = shopify.sum(:refunds)`、
  `total_tax = shopify.sum(:total_tax)`、`transaction_fees = shopify.sum(:transaction_fees)`。
- 計算 `net_revenue = gross_revenue − refunds − total_tax − transaction_fees`。
- 回傳 hash 加入這五個 key。
- **既有 `revenue` 及其衍生指標（gross_profit、roas、margins 等）維持原樣，不動。**

### 5. Dashboard View（`app/views/dashboard/show.html.erb`）

新增五張 `metric_card`，建議獨立成一組（放在現有 Revenue 卡片附近或其下一列）：

- Gross Revenue
- Refunds（`invert_color: true`，越低越好）
- Tax（`invert_color: true`）
- Transaction Fees（`invert_color: true`）
- Net Revenue

手續費卡片下方加一行小字說明「僅涵蓋 Shopify Payments 訂單」（i18n）。
所有標題走 i18n（`config/locales` 中英文，沿用 `dashboard.*` 命名）。

## 錯誤處理

- Shopify Payments 未啟用或 API 回 `shopifyPaymentsAccount: null` → 手續費 0，記 log，不中斷同步
  （沿用 `sync_date` 既有 `rescue => e` 記錄樣式）。
- balance transactions 分頁失敗／逾時 → 沿用現有例外處理，該日手續費不寫入（維持既有值或 0），不影響其他欄位。
- 新欄位有 DB 預設 0 與 `null: false`，聚合 `sum` 不會遇到 nil。

## 測試（依 CLAUDE.md：95%+ 覆蓋、無 mock、需 model/request/system spec）

- `spec/services/shopify_analytics_service_spec.rb`：
  - gross_revenue / refunds / total_tax（淨稅）分別寫入正確；
  - 有退款時淨稅 = 收稅 − 退稅；
  - Shopify Payments 未啟用時 transaction_fees = 0；
  - 手續費依日期歸屬正確。
- `spec/services/dashboard_metrics_service_spec.rb`：
  - 聚合四欄位與 net_revenue 公式；
  - net_revenue 一致性（用具體數字驗證抵銷）；
  - 既有 revenue／profit／margin 指標未受影響（回歸）。
- `spec/models/shopify_daily_metric_spec.rb`：新欄位預設值／驗證。
- `spec/requests/dashboard_spec.rb`：新指標出現於回應。
- `spec/system/`：dashboard 顯示五張新卡片。

## 範圍界線（YAGNI）

- **不改** Orders 列表頁的 `total_revenue`（`total_price` 加總）。此處與 dashboard 定義不一致為既有狀況，
  不在本次範圍；如需統一另開工作。
- **不做**完整「手續費覆蓋率」統計；僅一行靜態說明字。
- **不改**現有 `revenue` 欄位定義與其衍生指標。
- 手續費採固定費率估算的替代方案**不採用**（已決定用精確 API）。
