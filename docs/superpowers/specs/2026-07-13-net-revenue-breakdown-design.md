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
| `transaction_fees` | Shopify Payments 每筆訂單交易的真實手續費（GraphQL `OrderTransaction.fees`），依**訂單下單日**歸屬 |
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

手續費改由**訂單查詢內嵌**取得（見元件 3），不另做 API。

- 訂單抓取（`fetch_orders_via_graphql`）：目前把 `subtotal + shipping + tax` 合併回傳為單一
  `gross_revenue`。改為**同時**回傳 `gross_revenue`、其中的 `tax_charged`（`totalTaxSet` 的加總），
  以及 `transaction_fees`（每筆訂單 `transactions.fees.amount` 的加總）。
- 退款抓取（`fetch_refunds_via_graphql` / `fetch_refunds_for_status`）：目前回傳單一 `refunds_total`。
  改為**同時**回傳 `refunds_total` 與其中的 `tax_refunded`
  （`refundLineItems.totalTaxSet` + `refundShippingLines.taxAmountSet` 的加總）。
- `sync_date` 寫入：
  - `revenue`（維持 `gross_revenue − refunds_total`，不變）
  - `gross_revenue = gross_revenue`
  - `refunds = refunds_total`
  - `total_tax = tax_charged − tax_refunded`
  - `transaction_fees = transaction_fees`（來自訂單查詢）

### 3. Shopify Payments 手續費取得（內嵌於訂單查詢）

Shopify Admin GraphQL 的 `OrderTransaction.fees`（`[TransactionFee!]!`，官方註明「僅 Shopify Payments
交易有」）直接帶每筆交易的手續費，`TransactionFee.amount` 為 `MoneyV2`。因此手續費在現有訂單查詢裡一起抓即可：

```graphql
node {
  subtotalPriceSet { shopMoney { amount } }
  totalShippingPriceSet { shopMoney { amount } }
  totalTaxSet { shopMoney { amount } }
  customer { numberOfOrders }
  transactions(first: 10) {
    fees { amount { amount } }
  }
}
```

- 每筆訂單手續費 = 該訂單所有 `transactions` 的所有 `fees.amount.amount` 加總；再累加到當日總額。
- 若訂單非 Shopify Payments 交易，`fees` 為空陣列 → 該訂單手續費 0，不報錯。
- 日期歸屬：手續費隨訂單走，**依訂單下單日（created_at）歸屬**，與 gross_revenue 完全對齊，無日期錯位。
- 已知 caveat：太近期／未結算的訂單，`fees` 可能尚未產生（暫為 0）；每日同步與 backfill 重跑會自動補正。
- 多幣別：`TransactionFee.amount` 為交易/結算幣別（Shopify Payments 通常為店幣別），直接取用；
  極端多幣別情境的微小誤差列為已知限制。

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

- 訂單交易非 Shopify Payments → `transactions.fees` 為空 → 手續費 0，正常流程，不報錯。
- `transactions` 或 `fees` 缺漏／為 `nil` → 以 `|| []` 與 `.to_d` 保底為 0（沿用現有 `.to_s.to_d` 樣式）。
- 整體同步失敗 → 沿用 `sync_date` 既有 `rescue => e` 記錄 log，不中斷，不影響其他日期。
- 新欄位有 DB 預設 0 與 `null: false`，聚合 `sum` 不會遇到 nil。

## 測試（依 CLAUDE.md：95%+ 覆蓋、無 mock、需 model/request/system spec）

- `spec/services/shopify_analytics_service_spec.rb`：
  - gross_revenue / refunds / total_tax（淨稅）分別寫入正確；
  - 有退款時淨稅 = 收稅 − 退稅；
  - 訂單 `transactions.fees` 加總正確寫入 `transaction_fees`（多筆 transaction／多筆 fee）；
  - 訂單無 `fees`（非 Shopify Payments）時 transaction_fees = 0。
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
