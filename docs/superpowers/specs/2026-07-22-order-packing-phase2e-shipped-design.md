# 訂單打包 Phase 2E — 已交運 (shipped / 發貨) 設計文件

**日期**：2026-07-22（Codex 設計複審後修訂）
**分支**：`feature/order-packing-phase2e-ship`（從 `origin/staging` 切，已含 2A/2B/2C/2D）。
**流程**：SDD（brainstorming → 本設計 → writing-plans → 逐任務執行）。
**外部 API**：華磊 URL1 `postOrderApi.htm`（标记发货）；Shopify Admin GraphQL **`fulfillmentCreate`**（非 deprecated 的 V2）；17Track `TrackingService`。
**參考**：`docs/superpowers/references/raydo-huali-api.md`。

---

## 一、目標與範圍

`pending_label` 包裹「發貨」→ AASM `ship`（pending_label→shipped）**永遠執行**。每個店鋪(shopify_store)有一個**同步開關 `shipping_sync_enabled`**：開啟時，發貨額外執行三個外部副作用——**華磊标记发货 + 17Track 註冊 + Shopify 逐包裹回寫**；關閉時只轉狀態（測試/調 UI 用）。單筆 + 批量，權限 `package_shipping?`。

**測試工作流**：兩店先開關**關閉**做流程/UI 測試（只轉狀態）；確認後用戶會要「清包裹」腳本清測試資料，再開關**開啟**正式使用。（清包裹腳本為後續獨立需求，不在本階段。）

**非目標**：清包裹腳本；華磊 `updateOrderWeightByApi`/`selectTrack`；退貨/取消。

---

## 二、關鍵決策

| # | 決策 | 選定 |
|---|------|------|
| Q1 | 華磊标记发货 | 納入，受開關 gate |
| Q2 | 同步方式 | ship 同步轉狀態；三副作用背景 job；失敗維持 shipped + `ship_sync_status` 記錄 |
| Q3 | 觸發 / 權限 | 單筆 + 批量；`package_shipping?` |
| Q4 | Shopify 回寫粒度 | 逐包裹 fulfillment（package_items → fulfillment order line items 對映） |
| Q5 | 通知顧客 | `notifyCustomer: true` |
| Q6 | Shopify 寫入權限 | **加 OAuth 寫入 scope + 兩店重新授權(reauth)**；用 **`fulfillmentCreate`** |
| — | 17Track 重複 | 步驟2 直接註冊 + 回寫後 Fulfillment 自動註冊，重複**接受**（明確把「已註冊」判為成功） |

---

## 三、資料模型（migration）

**`shopify_stores`**：`shipping_sync_enabled`（boolean, default **false**, null:false）。

**`packages`**：
| 欄位 | 型別 | 用途 |
|------|------|------|
| `shipped_at` | datetime | ship 時間 |
| `ship_sync_status` | string, default "none", null:false | none/pending/succeeded/failed；`validates inclusion` |
| `ship_sync_message` | text | 失敗原因（安全訊息） |
| `carrier_marked_at` | datetime | 華磊标记发货 完成戳記 |
| `tracking_registered_at` | datetime | 17Track 註冊 完成戳記 |
| `shopify_fulfillment_id` | string | Shopify fulfillment id（已 fulfill 標記） |

**索引/約束（Codex）**：`add_index :packages, :ship_sync_status`（retry/admin 掃描）；`add_index :packages, :shopify_fulfillment_id, unique: true, where: "shopify_fulfillment_id IS NOT NULL"`（部分唯一，防重複回寫落庫）。無新 AASM state。

---

## 四、Shopify OAuth Scope + 重新授權（Codex Important #1）

現有 scope（`shopify_oauth_controller.rb:36`）僅 `read_...,write_webhooks`，**無寫入 fulfillment 權限**。本階段：
- OAuth 請求 scope **加入** `write_merchant_managed_fulfillment_orders`（`fulfillmentCreate` 對商家自管履約所需；若渠道用第三方履約另需 `write_third_party_fulfillment_orders`——本專案自建包裹屬 merchant-managed，先加前者）。
- **兩個既有店鋪必須重新授權**（重跑 OAuth，換取含新 scope 的 token）。
- **偵測與提示**：`ShopifyStore` 已存 `scopes`。加 `ShopifyStore#fulfillment_write_scope?`（檢查 `scopes` 是否含寫入 scope）。發貨同步時若店鋪開關開但缺此 scope → 該包裹 Shopify 步驟記為 failed + 提示「請重新授權店鋪」；店鋪設定頁在缺 scope 時顯示「重新授權」提示/連結。
- `fulfillmentCreate`（非 `fulfillmentCreateV2`，後者已 deprecated）。

---

## 五、`ship` 動作（Controller / routes）

gate `package_shipping?`（owner 通過）；`set_package`（跨公司 404）/ `scoped_packages`；非 `pending_label` 拒絕；失敗 redirect/422，**絕不 500**。

- `POST /packages/:id/ship`（member）；`POST /packages/ship_bulk`（collection）；`POST /packages/:id/sync_shipment`（member，手動同步/重試——見 §八）。

**`ship_package(package)`（原子化，Codex Important #3）**：在 `package.with_lock` 內做，避免雙擊/雙提交競態：
```
package.with_lock do
  next false unless package.pending_label?            # 已被別的請求 ship 過 → 安靜略過
  raise Abort if package.tracking_number.blank?       # 出貨前必須有運單號（Codex Minor #1）→ 422/alert，不 ship
  package.ship!                                        # pending_label → shipped
  package.update!(shipped_at: Time.current)
  if package.shopify_store.shipping_sync_enabled?
    package.update!(ship_sync_status: "pending", ship_sync_message: nil)
    enqueue = true
  end
end
PackageShipSyncJob.perform_later(package.id) if enqueue   # 鎖外 enqueue
```
批量：`scoped_packages.where(id:, aasm_state: "pending_label")` 逐筆 `ship_package`，per-package rescue（一筆失敗不阻斷批量），回報已發貨數。

---

## 六、`PackageShipSyncJob` + `PackageShipmentSyncer`（分步冪等）

只有店鋪開關開時被 enqueue。`perform(package_id)`：載入 package（仍 `shipped?` 才處理）→ `PackageShipmentSyncer.new(package).call`。

三步依序、各步先看完成戳記、已完成則跳過：

1. **華磊标记发货**（`carrier_marked_at` 空才做）：`Raydo#mark_shipped`（`URL1/postOrderApi.htm?customer_id=<channel.logistics_account.customer_id>&order_customerinvoicecode=<package_code>`）。**回應格式未文件化（Codex Critical #4）**：成功判準保守——HTTP 2xx 且回應可解析出 ack/成功標記才算成功；**無法辨識的回應一律判為 failed（不當成功、不盲目重試）**，記訊息待人工核對。成功存 `carrier_marked_at`。
2. **17Track 註冊**（`tracking_registered_at` 空才做）：需 `company.tracking_enabled?` + `tracking_api_key`（缺 → 跳過、記訊息、**不算失敗**）；`TrackingService#register([tracking_number])`。**Codex Important #2**：把「已註冊/重複」視為成功——檢查該 number 在 `accepted` 或已知的 duplicate-rejected code；只有真正錯誤才 failed。成功存 `tracking_registered_at`。
3. **Shopify 逐包裹回寫**（`shopify_fulfillment_id` 空才做）：見第七節。

結果：三步皆成/合理跳過 → `ship_sync_status="succeeded"`；任一失敗 → `"failed"` + `ship_sync_message`（安全訊息）。包裹**維持 shipped**。外部錯誤以 `FulfillmentService::Error`/rescue 包裝，job 不炸開。

---

## 七、Shopify 逐包裹回寫（`ShopifyFulfillmentService`）

用官方 `ShopifyAPI::Clients::Graphql::Admin`（沿用 `ShopifyAnalyticsService#build_graphql_client`）。

**Line item ID 正規化（Codex Critical #1）**：`order_line_items.shopify_line_item_id` 是 REST 數字(bigint)，GraphQL 回 GID（`gid://shopify/LineItem/<n>`）。對映時把數字轉 GID（`"gid://shopify/LineItem/#{shopify_line_item_id}"`）再比對 `fulfillmentOrderLineItem.lineItem.id`，兩路徑都寫測試。

**per-order 序列化（Codex Critical #2）**：折包訂單多包裹並發回寫同一 fulfillment order 會搶 `remainingQuantity`。**以 `order` row lock（`package.order.with_lock`）序列化同訂單的 Shopify 回寫**，鎖內才查 fulfillmentOrders + create，確保同訂單各包裹依序、依最新 remainingQuantity 建立。

**重試前對帳（Codex Critical #3）**：Shopify 建成功但回應逾時、`shopify_fulfillment_id` 沒存 → 重試前先查該訂單既有 fulfillments，比對本包裹的 tracking number + line items；已存在則**採用其 id**（不重建）；查不到才 `fulfillmentCreate`。仍無法確認 → 標 `ship_sync_message="需人工核對"`、failed，不盲建。（DB 部分唯一索引為最後防線。）

流程（鎖內）：
1. 查該訂單 open `fulfillmentOrders { id, lineItems { id, remainingQuantity, lineItem { id } } }`。
2. 對映本包裹每個 shippable `package_item`（`shopify_line_item_id`→GID）→ fulfillment order line item id + 出貨數量 `min(quantity-refunded_quantity, remainingQuantity)`；出貨數量須 > 0（Codex Minor #2：防 `refunded>quantity` 的髒資料）。
3. `fulfillmentCreate(fulfillment: { lineItemsByFulfillmentOrder: [{ fulfillmentOrderId, fulfillmentOrderLineItems: [{ id, quantity }] }], trackingInfo: { number, company: channel.shopify_carrier_name, url: <tracking_url_template 填 #TrackingNumber#> }, notifyCustomer: true })`。
4. `userErrors` 非空 → 失敗（安全訊息）；成功存 `shopify_fulfillment_id`。

**邊界**：無 open fulfillment order（已他處 fulfill）→ 記失敗/需人工；缺寫入 scope → 失敗提示 reauth；對不到 line item → 失敗記訊息。

---

## 八、手動同步 / 重試（Codex Important #4）

`POST /packages/:id/sync_shipment`（member，gate `package_shipping?`）：適用 `shipped` 且 `ship_sync_status ∈ {failed, none}`（none = 測試模式出貨、後來才開開關的補救路徑）。條件：該店鋪 `shipping_sync_enabled?` 為真才允許（否則提示先開開關）。動作：`ship_sync_status="pending"` + `PackageShipSyncJob.perform_later`（分步冪等，只補未完成步）。

店鋪設定頁：開啟 `shipping_sync_enabled` 前，若該店有 `shipped` 且 `ship_sync_status="none"` 的包裹，顯示提示「有 N 個已出貨包裹尚未同步，開啟後可逐一『立即同步』」。

---

## 九、UI

- **店鋪設定頁**：per-store `shipping_sync_enabled` 開關（標示 開＝正式同步；關＝測試只轉狀態）；缺寫入 scope 時顯示「重新授權」提示。
- **Modal（`_actions`）**：`pending_label` + `package_shipping?` → 「發貨」鈕。`shipped` 顯示 `ship_sync_status`（pending/succeeded/failed + 訊息）；failed 或 none（且開關開）給「立即同步」鈕。
- **`pending_label` 清單**：批量發貨（沿用 index 批量表單一般化，比照 2C/2D `package-bulk`）。
- i18n 三語系（發貨、同步狀態、重試、失敗/需人工訊息、店鋪開關、reauth 提示）。

---

## 十、Controller 細節（Codex Minor #3）

- 店鋪開關存 `ShopifyStoresController#update`：新增 `key?(:shipping_sync_enabled)` 分支，**owner-gated**（`current_membership&.owner?`，與其他店鋪設定一致），專屬 permit `params.require(:shopify_store).permit(:shipping_sync_enabled)`——不落入通用 update。
- 出貨動作在 `PackagesController`，gate `package_shipping?`。

---

## 十一、權限模型

`ship`/`ship_bulk`/`sync_shipment` gate 在 `package_shipping?`（owner 通過）。店鋪開關編輯 owner-gated。`PackageShipSyncJob` 系統背景，無權限。

---

## 十二、測試要求（CLAUDE.md 強制）

RSpec + FactoryBot，**不 mock DB、打真 DB、95%+**；外部 HTTP 用 **WebMock**（華磊/17Track/Shopify GraphQL 皆 stub）。每功能 model/service + request + system。

- **Model**：`ShopifyStore#shipping_sync_enabled` 預設 false + `#fulfillment_write_scope?`；`Package` ship 欄位/inclusion；部分唯一索引（同 shopify_fulfillment_id 重複落庫被擋）。
- **Service**：
  - `Raydo#mark_shipped`（成功/失敗/無法辨識回應→failed；憑證安全）。
  - `ShopifyFulfillmentService`：GID 正規化對映（數字↔GID）、逐包裹 line items+數量、`fulfillmentCreate` userErrors→失敗、無 open fulfillment order、缺 scope、重試前對帳（既有 fulfillment 採用其 id 不重建）。
  - `PackageShipmentSyncer`：三步全成/各步失敗/分步冪等（戳記跳過）、17Track 已註冊視為成功、17Track 缺 key→跳過不失敗、per-order 序列化（同訂單兩包裹不搶）。
- **Job**：落地各分支；仍 shipped 才處理。
- **Request**：`ship`（gate 雙向、404、非 pending_label、tracking 空→拒、toggle 開→enqueue+pending、toggle 關→不 enqueue+none、with_lock 下重複 ship 安靜略過）；`ship_bulk`（部分、per-package rescue）；`sync_shipment`（failed/none 補救、關開關時拒、權限）。
- **System**：發貨鈕、shipped 同步狀態、失敗/none 立即同步、批量、店鋪開關、缺 scope reauth 提示。
- 跨公司隔離、權限雙向、外部三整合成功/失敗/跳過 皆覆蓋。

---

## 十三、實作順序（給 writing-plans 的粗綱）

1. Migration：store `shipping_sync_enabled` + packages 6 欄 + 索引/部分唯一 + model 驗證/預設 + `ShopifyStore#fulfillment_write_scope?` + specs。
2. OAuth scope 加 `write_merchant_managed_fulfillment_orders`（+ 缺 scope 偵測/提示）+ specs。（部署後需兩店 reauth——營運步驟。）
3. `Raydo#mark_shipped` + WebMock specs（含未知回應→failed）。
4. `ShopifyFulfillmentService`（GID 正規化 + fulfillmentOrders 查詢 + `fulfillmentCreate` 逐包裹 + 重試前對帳）+ WebMock GraphQL specs。
5. `PackageShipmentSyncer`（三步、分步冪等、per-order 序列化、17Track 已註冊=成功、狀態/訊息）+ specs。
6. `PackageShipSyncJob` + specs。
7. Controller `ship`/`ship_bulk`/`sync_shipment` + routes + `ShopifyStoresController` 開關分支 + request specs（含 with_lock/toggle/none-補救）。
8. UI：發貨鈕、shipped 同步狀態 + 立即同步、清單批量、店鋪開關 + reauth 提示、i18n。
9. System specs。
10. 全套 rspec + rubocop + brakeman 綠燈；PR 到 staging（PR 內文標明**部署後兩店需 reauth** 才能 Shopify 回寫）。

---

## 十四、備註 / Codex 複審已吸收

- Codex Critical 1–4（GID 對映、per-order 序列化、重試前對帳、華磊未知回應保守判失敗）、Important 1–5（寫入 scope+reauth+`fulfillmentCreate`、17Track 已註冊=成功、ship row lock、none 補救路徑、DB 索引/部分唯一）、Minor 1–3（tracking 空值防護、出貨數量>0 防護、店鋪開關 controller 分支/permit）皆已納入上述章節。
- 17Track 直接註冊 與 回寫後 Fulfillment 自動註冊的重複——**接受**（用戶確認；已明確把「已註冊」判為成功以避免假失敗）。
- 華磊 `postOrderApi` 回應格式：實作前應取得真實回應樣本或向貨代確認；在此之前一律保守判定。
