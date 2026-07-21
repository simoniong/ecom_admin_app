# Phase 2A 設計:打包模塊基礎(包裹 + 狀態機 + 自動建立 + 列表)

日期:2026-07-21
分支:`feature/order-packing-phase2a`(基於 `origin/staging`)
所屬項目:訂單打包處理模塊(完整 PRD 見 `.plan/PRD_order_packing.md`;Raydo API 見 `.plan/raydo_api_notes.md`)。

## 範圍與切塊

Phase 2 太大,拆成可獨立上線的子塊:
- **2A(本文件)**:`Package` + `PackageItem` 資料模型、aasm 狀態機骨架、包裹 ID 升序序列、每店打包開關、**訂單同步後自動建包裹(待審核)**、全額退款→已退款、三個打包權限、側邊欄「打包」群組 + 各狀態的**唯讀**列表頁。
- 2B:待審核 + 待處理的操作(審核、分配物流、改地址/報關/備註、折包/合包、擱置/打回)。
- 2C:運單申請(FulfillmentService createOrder)+ 打單 + 發貨(Shopify 同步旗標)+ 換單號 + 補發。
- 2D:對帳共存(包裹 ID 匹配/非匹配雙模式)+ console 清包裹 script + 分階段 rollout 旗標。

**2A 明確不含**:任何狀態的操作按鈕/流程(審核、折包、運單申請、打單、發貨都在 2B/2C)。2A 只讓包裹能被自動生成、狀態/數量正確、可在列表看到。

## 資料模型

### `packages`(UUID PK)
- `shopify_store_id`(uuid, not null)、`order_id`(uuid, not null)
- `aasm_state`(string, not null)—— 主狀態
- `application_status`(string, not null, default "none")—— 運單申請子狀態:`none`/`pending`/`succeeded`/`failed`
- `held_from`(string, nullable)—— 擱置前的主狀態(還原用)
- `number`(integer, not null)—— 店內升序序號(取號用)
- `logistics_channel_id`(uuid, nullable)—— 2B 分配物流時填
- `note`(text, nullable)—— 備註
- 時間戳:`created_at`/`updated_at`(+ 之後各階段的操作時間留待 2B/2C 加,2A 不預先加)
- 索引:`unique(order_id)`(一訂單一包裹去重);`unique(shopify_store_id, number)`(取號保險);`index(shopify_store_id, aasm_state)`(列表/計數)

`package_code`(顯示用「前綴 + 補零到 7 位的 number」,如 `XMBDE2013094`)為 model 方法即時組出,不落庫(前綴改不了、number 不變,即時組永遠一致)。

### `package_items`(UUID PK)
- `package_id`(uuid, not null)、`product_variant_id`(uuid, nullable —— 對應商品,可能有 order line item 無對應 variant 的情況)
- `order_line_item_id`(uuid, nullable —— 來源 line item,便於追溯)
- `sku`(string)、`title`(string)、`quantity`(integer, not null)—— 建包裹時從 order line item 快照複製(折包/報關/建單以 package 的 items 為準)
- 索引:`index(package_id)`

### `shopify_stores` 新增欄位
- `packing_enabled`(boolean, not null, default false)—— 打包開關
- `package_prefix`(string, nullable)—— 包裹 ID 前綴(如 XMBDE)
- `package_number_start`(integer, nullable)—— 起始號
- `package_number_seq`(integer, nullable)—— 目前序號計數器(行鎖 +1 取號)

**鎖死規則**:`package_prefix`、`package_number_start` 一旦該店已有任何 package 就唯讀(model 驗證 + 設定頁 UI)。開打包開關前,前綴與起始號必填。

## 狀態機(aasm gem)

引入 `aasm` gem(專案首個用 gem 的狀態機;**不改動**既有手寫的 Ticket 狀態機)。

`Package` 的 aasm states:
- `pending_review`(待審核,**initial**)
- `pending_process`(待處理)
- `applying_tracking`(運單號申請)
- `pending_label`(待打單)
- `shipped`(已交運)
- `refunded`(已退款,**終態**)
- `held`(已擱置,**臨時**)

events(2A 定義轉換規則;實際 UI 觸發在 2B/2C):
- `submit_review`:pending_review → pending_process
- `apply_tracking`:pending_process → applying_tracking
- `to_label`:applying_tracking → pending_label
- `ship`:pending_label → shipped
- 打回類:`back_to_review`(pending_process → pending_review)、`back_to_process`(applying_tracking/pending_label → pending_process)
- `hold`:pending_review/pending_process/applying_tracking/pending_label → held(轉換前把當前狀態寫入 `held_from`)
- `unhold`:held → `held_from` 指定的狀態(還原;清空 `held_from`)
- `refund`:任何非終態 + shipped → refunded(終態)

`application_status` 由獨立欄位管理(2C 運單申請時流轉 pending→succeeded/failed),2A 只建欄位 + 預設 `none`。

轉換白名單完全對應 PRD 各狀態的異常規則(擱置/打回)。無效轉換由 aasm 擋下並回錯誤。

## 自動建立(掛勾 `SyncAllOrdersService#sync_order`)

新增一個 service(如 `PackageAutoBuilder` / 或直接在 sync_order 呼叫)在單筆訂單同步後執行:

觸發條件(全部滿足才建):
1. `order.shopify_store.packing_enabled?`
2. 訂單**已付款**、**未取消**、**未退款**(依 Shopify 訂單的 financial/fulfillment/cancel 狀態判斷,實作時對齊既有 Order 欄位)

行為:
- `Package.find_or_create_by(order_id:)` 去重(同步會重複跑:全量/增量/webhook)。
- 取號:`shopify_store.with_lock { seq = (package_number_seq || package_number_start); update!(package_number_seq: seq + 1); ... }`,`number = seq`。連續不跳號。
- 複製 order line items → PackageItem(sku/title/quantity 快照;連 product_variant 若可對應)。
- 初始狀態 `pending_review`。
- **只對開關打開後、新同步進來的訂單**(不回溯既有舊訂單;歷史 backfill 是 Phase 4)。

退款偵測(同步時):
- 若訂單本次同步發現轉為**全額退款**(部分退款不算),對應 package `refund!`(含已交運;終態)。若尚無 package(未開開關期間的訂單)則略過。

## UI(參考店小秘)

### 側邊欄
Level 1 新增「打包」nav-group,Level 2:
- 待審核 / 待處理 / 運單號申請 / 待打單 / 已交運
- 「其他」:已退款 / 已擱置

每項顯示該狀態的**數量 badge**(該店/公司範圍計數)。

### 各狀態列表頁(唯讀,共用列表元件)
- 一列一包裹:**包裹 ID 為列首**,底下列該包裹的商品(SKU / 數量 / 縮圖)、訂單金額、收件人國家、訂單號、時間戳、物流方式、狀態。
- 頂部篩選:店鋪、國家、搜尋(訂單號/SKU/包裹ID)。分頁。
- 運單號申請頁:tab 分「申請中 / 申請成功 / 申請失敗」(依 `application_status`)。
- 已擱置頁:每列顯示 `held_from` 原狀態(還原操作留 2B)。
- **2A 不含操作按鈕**;純展示。

## 權限

`Membership::AVAILABLE_PERMISSIONS` 新增三個:`package_review`、`package_process`、`package_shipping`。
- 2A 的列表頁:**有任一打包權限**(或 owner)即可檢視。
- 各操作的細分權限(審核=package_review、處理/折包/運單申請=package_process、打單&發貨=package_shipping)在 2B/2C gate。
- `PERMISSION_KEY_MAP`:打包相關 controller 映射到適當權限;列表頁的 gate 用「任一打包權限」的自訂判斷(非單一 permission_key)。
- membership 編輯 UI 自動列出三個新權限(+ i18n label,三語)。

## 每店設定 UI(Shopify Store 設定頁)
- 新增一區:打包開關(布林)+ 包裹前綴 + 起始號。前綴/起始號在該店已有包裹後唯讀。owner 權限(比照既有 store 設定)。
- 開開關前,前綴 + 起始號必填(驗證)。

## 測試(維持 95%+ 覆蓋率)
- **Model(Package)**:aasm 各轉換(合法/非法)、hold 寫 held_from + unhold 還原、refund 終態(含 shipped→refunded)、`package_code` 格式、number 併發取號(行鎖不重號)。
- **Model(ShopifyStore)**:前綴/起始號有包裹後唯讀驗證;開開關需前綴+起始號。
- **自動建立**:掛勾條件(開關/已付款/未取消未退款)、去重(unique order_id、重複同步不重建)、不回溯、複製 items 正確、全額退款→refunded、部分退款不動。
- **Request**:三權限 gate(有任一可看列表;皆無被擋)、各狀態列表頁、運單申請 tab、已擱置顯示原狀態。
- **System**:側邊欄「打包」群組展開 + 各子頁 + 數量 badge。
- i18n:en / zh-TW / zh-CN 全部新標籤 + 三個權限 label + 狀態名稱。

## 待釐清(留待 2B/2C,不擋 2A)
- 「已付款/未取消/未退款」對應 Order 的哪些實際欄位(實作時對齊既有 Order model)。
- 全額退款的判定(Shopify financial_status == "refunded" vs 金額比對)——實作時確認 Order 現有欄位。
- package_code 是否需要落庫供對帳查詢(2D 對帳時再定;2A 先即時組)。
- 訂單金額/收件國等展示欄位從 Order 讀取的確切來源(實作時對齊)。
