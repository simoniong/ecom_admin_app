# 訂單打包 Phase 2E — 已交運 (shipped / 發貨) 設計文件

**日期**：2026-07-22
**分支**：`feature/order-packing-phase2e-ship`（從 `origin/staging` 切，已含 2A/2B/2C/2D）。
**流程**：SDD（brainstorming → 本設計 → writing-plans → 逐任務執行）。
**外部 API 參考**：`docs/superpowers/references/raydo-huali-api.md`（華磊 URL1 `postOrderApi.htm` 标记发货）；Shopify Admin GraphQL `fulfillmentCreateV2`；17Track `TrackingService`。

---

## 一、目標與範圍

`pending_label` 包裹「發貨」→ AASM `ship`（pending_label→shipped）**永遠執行**。每個店鋪(shopify_store)有一個**同步開關**：開啟時，發貨額外執行三個外部副作用——**華磊标记发货 + 17Track 註冊 + Shopify 逐包裹回寫**；關閉時只轉狀態（測試/調 UI 用）。單筆 + 批量，權限 `package_shipping?`。

**測試工作流（用戶意圖）**：兩個店鋪先各自開關**關閉**做流程/UI 測試（只轉狀態，不污染 17Track/Shopify/貨代）；確認後，用戶會另外要求「清包裹」腳本清掉測試包裹，再把開關**開啟**正式使用。（清包裹腳本是後續獨立需求，不在本階段。）

**非目標**：清包裹腳本（後續）；華磊 `updateOrderWeightByApi`/`selectTrack`；退貨/取消流程。

---

## 二、關鍵決策（brainstorming 拍板）

| # | 決策 | 選定 |
|---|------|------|
| Q1 | 華磊标记发货 是否納入 | **納入，且受開關 gate**（開啟才做 postOrderApi） |
| Q2 | 同步方式 | **A：ship 狀態轉換同步；三副作用丟背景 job；失敗維持 shipped** + **sync 狀態記錄** |
| Q3 | 觸發 / 權限 | 單筆 + 批量；`package_shipping?` |
| Q4 | Shopify 回寫粒度 | **A：逐包裹 fulfillment**（package_items → fulfillment order line items 對映） |
| Q5 | 通知顧客 | **A：`notifyCustomer: true`** |
| — | 17Track 註冊 | 沿用 `TrackingService#register`（不帶 carrier、自動偵測）；與回寫後 Fulfillment 自動註冊的重複**接受**（17Track 冪等去重） |

---

## 三、資料模型（migration）

**`shopify_stores`**：
- `shipping_sync_enabled`（boolean, default **false**, null:false）——測試模式為預設。

**`packages`**：
| 欄位 | 型別 | 用途 |
|------|------|------|
| `shipped_at` | datetime | ship 時間 |
| `ship_sync_status` | string, default "none", null:false（none/pending/succeeded/failed）| 同步整體狀態 |
| `ship_sync_message` | text | 失敗原因（安全訊息，不外露憑證） |
| `carrier_marked_at` | datetime | 華磊标记发货 完成戳記（重試跳過用） |
| `tracking_registered_at` | datetime | 17Track 註冊 完成戳記 |
| `shopify_fulfillment_id` | string | Shopify 回寫成功的 fulfillment id（兼作「已 fulfill」標記，重試不重複建立） |

`ship_sync_status` 加 `validates inclusion: %w[none pending succeeded failed]`。無新 AASM state（`ship`/`shipped` 已存在）。

---

## 四、`ship` 動作（Controller / routes）

gate `package_shipping?`（owner 通過）；`set_package`（跨公司 404）/ `scoped_packages`；非 `pending_label` 拒絕；失敗 redirect/422，**絕不 500**。

- `POST /packages/:id/ship`（member）：`ship_package(@package)`；turbo_stream 重繪 modal。
- `POST /packages/ship_bulk`（collection）：`package_ids[]` → `scoped_packages.where(id:, aasm_state: "pending_label")` → 逐筆 `ship_package`，回報已發貨數；per-package rescue（一筆 InvalidTransition 不阻斷批量）。
- `POST /packages/:id/retry_ship_sync`（member）：僅 `shipped` 且 `ship_sync_status="failed"` → 重設 pending + re-enqueue（job 分步冪等，跳過已完成步驟）。

`ship_package(package)` 私有邏輯：
```
package.ship!  (pending_label → shipped)
package.update!(shipped_at: now)
if package.shopify_store.shipping_sync_enabled?
  package.update!(ship_sync_status: "pending", ship_sync_message: nil)
  PackageShipSyncJob.perform_later(package.id)
end   # 關閉時 ship_sync_status 維持 "none"（純轉狀態）
```

---

## 五、`PackageShipSyncJob`（非同步、分步冪等）

只有店鋪開關開時才被 enqueue。`perform(package_id)`：載入 package（防禦：仍 `shipped?` 才處理）→ `PackageShipmentSyncer.new(package).call`。

**`PackageShipmentSyncer`** 依序執行三步，各步先看完成戳記、已完成則跳過：
1. **華磊标记发货**（`carrier_marked_at` 空才做）：`FulfillmentService::Raydo#mark_shipped(order_customerinvoicecode: package.package_code)` → GET `URL1/postOrderApi.htm?customer_id=<account.customer_id>&order_customerinvoicecode=<package_code>`；成功存 `carrier_marked_at`。
2. **17Track 註冊**（`tracking_registered_at` 空才做）：需 `company.tracking_enabled?` + `tracking_api_key`（缺 → 跳過並記訊息，不算失敗）；`TrackingService.new(api_key:).register([package.tracking_number])`；成功存 `tracking_registered_at`。
3. **Shopify 逐包裹回寫**（`shopify_fulfillment_id` 空才做）：見第六節；成功存 `shopify_fulfillment_id`。

結果：三步皆成（或合理跳過）→ `ship_sync_status="succeeded"`；任一失敗 → `"failed"` + `ship_sync_message`（class-only/安全）。包裹**維持 shipped**。所有外部呼叫以既有 `FulfillmentService::Error` / rescue 包裝，job 不炸開（逐筆 log）。

---

## 六、Shopify 逐包裹回寫

用官方 `ShopifyAPI::Clients::Graphql::Admin`（沿用 `ShopifyAnalyticsService#build_graphql_client` 的 session 建法）。

1. 查該訂單的 `fulfillmentOrders`（open）與其 line items：GraphQL `order(id:) { fulfillmentOrders(first:…) { id, lineItems { id, remainingQuantity, lineItem { id } } } }`（`lineItem.id` = Shopify line item GID）。
2. 對映：本包裹每個 shippable `package_item` 的 `order_line_item.shopify_line_item_id` → 找到對應 fulfillment order line item id + 出貨數量（`quantity - refunded_quantity`）。
3. `fulfillmentCreateV2(fulfillment: { lineItemsByFulfillmentOrder: [{ fulfillmentOrderId, fulfillmentOrderLineItems: [{ id, quantity }] }], trackingInfo: { number: tracking_number, company: channel.shopify_carrier_name, url: <tracking_url_template 填號> }, notifyCustomer: true })`。
4. 回應 `fulfillment.id` → 存 `shopify_fulfillment_id`；`userErrors` 非空 → 失敗（訊息安全化）。

**邊界**：訂單在 Shopify 已無 open fulfillment order（例如已在他處 fulfill）→ 記為失敗/跳過並提示（不炸）；找不到對應 line item → 該包裹回寫失敗並記訊息。`tracking_url_template` 以 `#TrackingNumber#` 佔位替換運單號。

---

## 七、UI

- **店鋪設定頁**（`shopify_stores` 顯示/設定處）：每店一個 `shipping_sync_enabled` 開關（清楚標示「開＝正式同步 17Track/Shopify/貨代；關＝測試模式，只轉狀態」）。
- **Modal（`_actions`）**：`pending_label` + `package_shipping?` → 「發貨」鈕（button_to turbo）。`shipped` 顯示 `ship_sync_status`：pending「同步中」/ succeeded「已同步」/ failed「同步失敗」+ `ship_sync_message` + 「重試同步」鈕（`package_shipping?`）。測試模式（status none）不顯示同步區塊。
- **`pending_label` 清單**：多選批量發貨（沿用 index 批量表單一般化，比照 2C/2D 的 `package-bulk`）。
- 沿用 `dom_id` + 局部 `turbo_stream` replace；i18n 三語系（發貨、同步狀態、重試、失敗訊息、店鋪開關）。

---

## 八、權限模型

`ship` / `ship_bulk` / `retry_ship_sync` gate 在 `Membership#package_shipping?`（owner 通過）。店鋪開關編輯沿用既有店鋪設定權限。`PackageShipSyncJob` 是系統背景，無權限。

---

## 九、測試要求（CLAUDE.md 強制）

RSpec + FactoryBot，**不 mock DB、打真 DB、95%+ coverage**；外部 HTTP 用 **WebMock**（華磊、17Track、Shopify GraphQL 皆 stub）。每功能 model/service + request + system。

- **Model**：`ShopifyStore#shipping_sync_enabled` 預設 false；`Package` ship 欄位/inclusion。
- **Service**：
  - `Raydo#mark_shipped`（WebMock postOrderApi 成功/失敗、憑證安全）。
  - `PackageShipmentSyncer`：三步全成 → succeeded；各步分別失敗 → failed + message；分步冪等（已有戳記則跳過、Shopify 有 fulfillment_id 不重複建立）；17Track 缺 api_key → 跳過不算失敗；重試只補未完成步。
  - Shopify 回寫：fulfillmentOrders 查詢 + fulfillmentCreateV2 對映（逐包裹 line items + 數量），userErrors → 失敗；無 open fulfillment order 邊界。
- **Job**：`PackageShipSyncJob` 落地各分支；仍 shipped 才處理。
- **Request**：`ship`（gate 雙向、跨公司 404、非 pending_label 拒絕、toggle 開→enqueue+status pending、toggle 關→不 enqueue+status none）；`ship_bulk`（部分、per-package rescue）；`retry_ship_sync`。
- **System**：發貨鈕、shipped 同步狀態顯示、failed 重試、批量、店鋪開關切換。
- 跨公司隔離、權限雙向、外部三整合成功/失敗/跳過路徑 皆覆蓋。

---

## 十、實作順序（給 writing-plans 的粗綱）

1. Migration：store `shipping_sync_enabled` + packages 6 欄 + model 驗證/預設 + specs。
2. `FulfillmentService::Raydo#mark_shipped` + WebMock specs。
3. Shopify 回寫：`ShopifyFulfillmentService`（或 `ShopifyService#create_fulfillment`）—— fulfillmentOrders 查詢 + fulfillmentCreateV2 逐包裹對映 + WebMock GraphQL specs。
4. `PackageShipmentSyncer`（編排三步、分步冪等、狀態/訊息）+ specs。
5. `PackageShipSyncJob` + specs。
6. Controller `ship`/`ship_bulk`/`retry_ship_sync` + routes + request specs（含 toggle 開/關 enqueue 行為）。
7. UI：發貨鈕、shipped 同步狀態 + 重試、清單批量、店鋪開關、i18n。
8. System specs。
9. 全套 rspec + rubocop + brakeman 綠燈；PR 到 staging。

---

## 十一、備註

- 17Track 步與「回寫後 Fulfillment 自動 `register_tracking`」可能各註冊一次——17Track 冪等去重，**接受**（用戶確認）。
- `ship_sync_status` 的 pending 若長期未 succeeded，可日後加 recurring 重試/告警（本階段先靠人工「重試同步」；不做自動 poller，因三步都是一次性動作而非等待外部出號）。
- 華磊 `postOrderApi` 回應格式沿用既有 GBK/單引號解析；`mark_shipped` 判斷成功以回應 ack/狀態為準（實作時對照實際回應）。
