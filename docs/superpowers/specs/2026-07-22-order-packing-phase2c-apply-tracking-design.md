# 訂單打包 Phase 2C — 申請運單號 (apply tracking) 設計文件

**日期**：2026-07-22
**分支**：（新開）從 `origin/staging` 切 `feature/order-packing-phase2c`
**前置**：2B-1/2A/2B-2 已合併 staging；2B-3（折包/合併）在 PR #212 待合併。2C 不依賴 2B-3 程式碼（僅共用同一 packing 模組與 per-package readiness），可獨立開發。
**流程**：SDD（brainstorming → 本設計 → writing-plans → 逐任務執行）。
**外部 API 參考**：`docs/superpowers/references/raydo-huali-api.md`（华磊/sz56t 建單與取號接口，原文 `raydo-huali-api-raw.txt`）。

---

## 一、目標與範圍

在 `pending_process`（待處理）狀態下，操作者對齊全的包裹按「申请运单号」，系統向華磊(Raydo)貨代**建單並取回運單號**，成功後包裹進 `pending_label`。支援**單筆**與**批量**申請。

**非目標（延後到後續階段）**：
- 印面單（華磊 URL2 `postOrderApi`/`selectLabelType`）。
- **17Track 軌跡註冊 + Shopify tracking 回寫**——按用戶決策，延到包裹「已交運(shipped)」的 `ship` transition 才做（出貨前運單號可能被打回）。
- 華磊 `createOrderBatchApi` 批量接口（本階段批量以「fan-out 單筆 job」實作，不用批量接口）。

---

## 二、關鍵決策（brainstorming 拍板）

| # | 決策 | 選定 |
|---|------|------|
| Q1 | 範圍 | **A：只建單+取號→pending_label**；17Track/Shopify 延到 shipped |
| — | 觸發方式 | **C：單筆 + 批量都做**；批量 = fan-out 單筆 job；批量逐筆跳過不齊全 |
| Q3 | 延遲取號機制 | **A：週期性輪詢 job**（每 5 分鐘），24h 未出號放棄→failed |
| Q4a | 失敗重試冪等 | 已有 `raydo_order_id`→只輪詢不重建；無→才重建 |
| Q4b | back_to_process | **Y：一律允許、清空申請欄位**；再申請會在華磊新建一筆（重複付費風險用戶承擔） |
| Q5 | 權限 | **B：`package_process?`**（與折包/合併/hold 同一把） |
| Q6 | 輪詢放棄上限 | **A：24 小時**（cadence 5 分鐘）；放棄後 failed 留 applying_tracking 供人工重試 |

**沿用 2B-2 決策**：齊全 gate 就在此階段的「申请运单号」按鈕（`ready_for_tracking?`）；審核放行無條件。

---

## 三、資料模型（migration）

packages 新增欄位（`application_status` 已存在，值 none/pending/succeeded/failed）：

| 欄位 | 型別 | 用途 |
|------|------|------|
| `raydo_order_id` | string | 華磊回傳的 `order_id`，供輪詢取號 + 之後印面單 |
| `tracking_number` | string | 運單號（`tracking_number` 或輪詢的 `order_serveinvoicecode`） |
| `carrier` | string | 快遞類型（`express_type`，選填，供之後 17Track/面單） |
| `application_message` | text | 失敗原因（華磊 `message` urldecode 後）或「超时未出号」 |
| `applied_at` | datetime | 申請（建單）時間，供輪詢 24h 放棄上限計算 |

無新 AASM state。既有 `apply_tracking`（pending_process→applying_tracking）、`to_label`（applying_tracking→pending_label）、`back_to_process`（[applying_tracking, pending_label]→pending_process）沿用。

`back_to_process` 加 AASM `after`：清空上述 5 欄（`application_status`→"none"），比照 unhold 的 `update_columns` 手法（after 跑在 save 之後，需直接 persist）。

---

## 四、華磊 adapter：`FulfillmentService::Raydo` 新增方法

沿用既有 `get`/`parse_response`/`decode_body`（GBK 轉碼、單引號偽 JSON、URL 憑證不外洩）。建單是 POST，需新增 post 輔助。

### `create_order(package)` → `CreateResult`
POST `URL1/createOrderApi.htm`，body `param=<URL 編碼的 JSON>`。

請求 JSON 映射：
- 收件：`consignee_name`←snapshot name、`consignee_address`←address1(+address2)、`consignee_telephone`←phone、`country`←country_code、`consignee_state`←province、`consignee_city`←city、`consignee_postcode`←zip、`consignee_companyname`←company。
- `product_id`←`package.logistics_channel.product_id`。
- `order_customerinvoicecode`←`package.package_code`（原单号,必填）。
- `customer_id`/`customer_userid`←`package.logistics_channel.logistics_account`（欄位已存；空則先 `authenticate` 補）。
- `weight`←各未全退 item `customs_weight_grams×(quantity-refunded_quantity)` 加總，換算為華磊單位（**假設 kg**：grams/1000；正式對接時向貨代確認單位，寫成常數便於調整）。
- `order_piece`←預設 1。
- `orderInvoiceParam[]`（對每個 `shippable_items`，即未全退）：`invoice_title`←`customs_name_en`、`sku`←`customs_name_zh`、`invoice_amount`←`declared_value_usd`、`invoice_weight`←`customs_weight_grams`(換算)、`invoice_pcs`←`quantity-refunded_quantity`、`hs_code`/`import_hs_code`←同名欄。

`CreateResult`（Struct）：
- `success?`（`ack=="true"`）
- `order_id`
- `tracking_number`（可空）
- `deferred?`（`is_delay=="Y"` 或 `product_tracknoapitype=="3"` 或 `tracking_number` 空）
- `message`（urldecode 後的失敗原因）

### `get_tracking_number(order_id)` → `TrackResult`
GET `URL1/getOrderTrackingNumber.htm?order_id=<id>`。

`TrackResult`：`ready?`（`status=="200"` 且 `order_serveinvoicecode` 非空）、`tracking_number`(=`order_serveinvoicecode`)、`carrier`(=`express_type`)、`message`(=`msg`)。

---

## 五、編排 service：`PackageTrackingApplier`

`PackageTrackingApplier.new(package).call`（在 `ApplyTrackingJob` 內執行；假設 package 已在 `applying_tracking`）。邏輯：

```
account/channel 缺失 → failed + message（設定不完整）
若 package.raydo_order_id 存在（重試路徑）:
    r = raydo.get_tracking_number(raydo_order_id)
    r.ready? → 存 tracking_number/carrier, succeeded, to_label!
    else     → 維持 pending（交輪詢 job；或 failed 若判定不可恢復）
否則:
    r = raydo.create_order(package)
    !r.success? → application_status=failed, application_message=r.message（留 applying_tracking）
    r.success? 且 !r.deferred? → 存 raydo_order_id + tracking_number, applied_at, succeeded, to_label!
    r.success? 且 r.deferred?  → 存 raydo_order_id, applied_at, application_status=pending（留 applying_tracking，交輪詢）
```

所有華磊呼叫以 `FulfillmentService::Error` 包裝；service 捕捉 → `failed` + 錯誤訊息，絕不讓 job 例外炸開（job 仍記錄）。

---

## 六、Jobs（Solid Queue）

### `ApplyTrackingJob(package_id)`
單筆申請與批量 fan-out 共用。載入 package（防禦：仍在 applying_tracking 才處理）→ `PackageTrackingApplier.new(package).call`。

### `PollTrackingNumbersJob`（recurring，每 5 分鐘）
掃 `aasm_state=applying_tracking AND application_status=pending AND raydo_order_id 非空` 的包裹（跨所有 store）：
- `raydo.get_tracking_number(raydo_order_id)`：`ready?`→存號、`succeeded`、`to_label!`。
- 否則若 `applied_at` 距今 > 24h → `application_status=failed` + `application_message="超时未出号"`（留 applying_tracking）。
- 否則維持 pending，下輪再試。
- 單包裹例外不影響其他（逐筆 rescue + log）。

以 Solid Queue recurring 設定註冊（比照既有 17Track 每小時刷新的排程）。放棄上限與 cadence 定為常數。

---

## 七、Controller / routes

全部先 `set_package`（`scoped_packages.find` → 跨公司 404）再 gate `current_membership&.package_process?`；失敗一律 422 或 redirect，**絕不 500**。沿用現有 `respond_to` turbo_stream/html 模式。

- `post :apply_tracking`（member）：
  - 非 `pending_process` → 拒絕（redirect/alert）。
  - `!ready_for_tracking?` → 422，重繪 readiness（顯示 `tracking_blockers`），不 transition。
  - 否則 `apply_tracking!`（→applying_tracking，`application_status="pending"`）→ `ApplyTrackingJob.perform_later(id)` → turbo_stream 重繪 modal/row。（`applied_at` 不在此設；由 applier 在華磊**建單成功**時設定，才是 24h 輪詢上限的正確錨點，且 retry 重建時自然重置。）
- `post :retry_tracking`（member）：僅 `applying_tracking` 且 `application_status=failed` → 重設為 pending → `ApplyTrackingJob.perform_later(id)`（applier 內冪等：有 order_id 則輪詢、無則重建）。
- `post :apply_tracking_bulk`（collection）：
  - 收 `package_ids[]`，`scoped_packages.where(id:, aasm_state: "pending_process")`。
  - 逐筆：`ready_for_tracking?` 者 → `apply_tracking!` + enqueue；不齊全者 → 記入 skipped。
  - 回報「已申請 N 筆、跳過 M 筆（不齊全）」（flash/turbo_stream）。
- `back_to_process`（既有 `transition` action，PROCESS_EVENTS）：model 的 after 清空申請欄位（見 §三）。

routes：packages member 加 `apply_tracking`、`retry_tracking`；collection 加 `apply_tracking_bulk`。

---

## 八、UI

沿用 Modal + `dom_id` + 局部 `turbo_stream` replace，及既有 `readiness`/`actions` partial 與 `bulk_select_controller`。

- **pending_process**：
  - `ready_for_tracking?` → `_actions` 顯示「申请运单号」鈕（`package_process?`）。
  - 不齊全 → 鈕停用；`_readiness` 已顯示 blockers（沿用）。
- **applying_tracking**（依 `application_status`）：
  - `pending` → 顯示「申请中 / 等待货代出号」狀態。
  - `failed` → 顯示 `application_message` + 「重试」鈕。
  - 顯示 `tracking_number`（若有）。
- **批量**：待處理清單列多選（`bulk_select_controller`）+ 頂部「申请运单号」批次鈕 → `apply_tracking_bulk`；結果 flash「已申請/跳過」。
- 新 i18n keys（en/zh-TW/zh-CN 結構一致）：按鈕、狀態、blockers 提示、批次結果、失敗/超时訊息。

---

## 九、權限模型

`apply_tracking` / `retry_tracking` / `apply_tracking_bulk` gate 在 `Membership#package_process?`（owner 通過），與折包/合併/hold/改資料同。`PollTrackingNumbersJob` 是系統排程，無權限。`package_shipping` 留給之後的面單/出貨鏈。

---

## 十、測試要求（CLAUDE.md 強制）

RSpec + FactoryBot，**不 mock DB、打真 DB、95%+ line coverage**；外部 HTTP 用 **WebMock `stub_request`**（既有 `raydo_spec` 慣例，`disable_net_connect`）。每功能 model/service + request + system。

- **Model**：`back_to_process` 清空申請欄位（applying_tracking→ 與 pending_label→ 兩來源）；`apply_tracking`/`to_label` 轉換；欄位驗證。
- **Service**：
  - `Raydo#create_order`：三分支解析（當場出號 / 延遲(is_delay=Y、tracknoapitype=3、號空) / ack=false 失敗 message urldecode）；GBK 響應；請求映射正確（stub 檢查 param）。
  - `Raydo#get_tracking_number`：ready(status=200+serveinvoicecode) / 未出號。
  - `PackageTrackingApplier`：重試冪等（有 order_id 只輪詢）、各分支狀態/欄位、帳號/渠道缺失、`FulfillmentService::Error` 不炸開。
- **Job**：`ApplyTrackingJob` 各分支落地；`PollTrackingNumbersJob` 出號→to_label、24h→failed、未到期維持 pending、逐筆隔離。
- **Request**：`apply_tracking`（gate 雙向、跨公司 404、非 pending_process 拒絕、不齊全 422+blockers、成功 enqueue+transition）；`retry_tracking`；`apply_tracking_bulk`（部分跳過、scoped、權限）；`back_to_process` 清欄位。
- **System（真 Chrome）**：申请运单号 按鈕→applying_tracking pending UI；failed→重试；批量多選→結果提示；不齊全鈕停用。
- 跨公司隔離、權限雙向、外部 API 成功/失敗/延遲三路徑 皆需覆蓋。

---

## 十一、實作順序（給 writing-plans 的粗綱）

1. Migration：packages 加 5 欄。
2. Model：`back_to_process` after 清欄位 + specs。
3. `FulfillmentService::Raydo#create_order` + `#get_tracking_number`（+ post 輔助、Result structs）+ WebMock specs。
4. `PackageTrackingApplier` service + specs。
5. `ApplyTrackingJob` + `PollTrackingNumbersJob`（+ recurring 註冊）+ specs。
6. Controller `apply_tracking`/`retry_tracking`/`apply_tracking_bulk` + routes + request specs。
7. UI：`_actions` 申请/重试 鈕、applying_tracking 狀態呈現、批量多選 + 批次鈕、i18n、turbo_stream。
8. System specs。
9. 全套 rspec + rubocop + brakeman 綠燈；PR 到 staging（`git push -u origin feature/order-packing-phase2c`）。
