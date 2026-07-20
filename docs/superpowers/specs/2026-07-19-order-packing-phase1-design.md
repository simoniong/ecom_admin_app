# Phase 1 設計:商品報關信息 + 物流渠道管理

日期:2026-07-19
分支:`feature/order-packing-phase1`(基於 `origin/staging`)
所屬項目:訂單打包處理模塊(完整 PRD 見 `.plan/PRD_order_packing.md`)。本文件只涵蓋 **Phase 1**。

## 範圍

Phase 1 交付兩個模塊(**不含**打包模塊本身,那是 Phase 2):
1. **商品報關信息** —— 每個 SKU 的報關資料 + 管理 UI(單筆 + 批量編輯)。
2. **物流渠道管理** —— Raydo 物流帳號與渠道設定(用 Raydo API 拉渠道清單)。

不在本階段:包裹建立、包裹狀態機、運單申請(createOrderApi)、打標籤、標記發貨、Shopify tracking 同步、包裹 ID 序列。這些留待 Phase 2。

---

## 模塊一:商品報關信息

### 資料模型
在 `product_variants` 新增欄位(SKU 層級):
- `customs_name_zh`(string)—— 中文品名
- `customs_name_en`(string)—— 英文品名
- `declared_value_usd`(decimal 10,2)—— 申報金額(USD)
- `hs_code`(string)—— 海關編碼
- `import_hs_code`(string)—— 進口海關編碼

申報重量**沿用既有 `weight_grams`**(不另開欄位)。

### 必填與強制(選項 A:編輯時強制)
- **必填 4 項**:`customs_name_zh`、`customs_name_en`、`declared_value_usd`、`weight_grams`。
- **強制落點 = 編輯時**:在報關編輯(單筆 + 批量)存檔時,若該次要寫入報關資料,則 4 個必填**必須一起齊全才能存**,不能存半套(context 驗證,非全表硬驗證)。
- Shopify 同步進來的空 variant **允許存在**(不阻擋同步),只標記為「未完成」。
- Model 提供 `customs_complete?`(4 項皆有值)。報關頁提供「未完成」篩選,快速找出還沒填的 SKU。
- 對應 Raydo 建單報關欄位(Phase 2 用):`customs_name_en`→`invoice_title`、`customs_name_zh`→`sku`、`declared_value_usd`→`invoice_amount`、`hs_code`→`hs_code`、`import_hs_code`→`import_hs_code`。

### UI:Products 改成 nav-group
- 側邊欄「Products」由單一 Level-1 連結改為**可展開 nav-group**,底下兩個子項:
  - **商品成本** = 現有 `products#index`(成本/重量頁,不動)
  - **報關信息** = 新頁(SKU 層級表格)
- **報關信息頁**沿用現有成本頁的模式:搜尋、store 選擇、分頁、單筆 inline 編輯 + 批量更新。欄位:image / product / variant / sku + 5 個報關欄位 + weight + 「完成/未完成」標示 + 「未完成」篩選。

### 權限(新增 `products`)
- 在 `Membership::AVAILABLE_PERMISSIONS` 新增 `products`。
- 整個 Products 群組(成本頁 + 報關頁)gate 在 `products` 權限。
- `PERMISSION_KEY_MAP`:`products`、`product_variants`、以及新報關 controller 都映射到 `products`(目前 `products`/`product_variants` 映射到 `shopify_stores`,改為 `products`)。
- **遷移影響**:現有只有 `shopify_stores` 權限的成員會**失去 Products 存取**,需由 owner 另外授予新 `products` 權限;owner 不受影響。membership 編輯 UI 會自動列出新權限(它迭代 `AVAILABLE_PERMISSIONS`),需補 i18n label。

### Controller / route(大方向,細節留 plan)
- 新 `ProductCustomsController#index`(報關頁,controller_name = `product_customs`,映射 `products` 權限)。
- 單筆報關寫入沿用/擴充 `ProductVariantsController#update`(permit 新報關欄位 + context 必填驗證);批量報關用一個 `bulk_update`-類 collection action。

---

## 模塊二:物流渠道管理

### 資料模型(兩張表,公司層級)
- **`logistics_accounts`**:一個物流商帳號(帳密共用)
  - `company_id`(uuid)、`provider`(string,先只有 `"raydo"`)
  - `username`(string)、`password`(**`encrypts`** 加密)
  - `customer_id`、`customer_userid`(string,認證後快取,建單用)
  - `url1_base`(string,建單/查詢 API,如 URL1)、`url2_base`(string,打標籤 API,如 URL2)
  - unique(`company_id`, `provider`)
- **`logistics_channels`**:一個帳號底下的多條線
  - `logistics_account_id`(uuid)
  - `name`(string,別稱,顯示於打包分配物流)
  - `product_id`(string,Raydo 運輸方式ID)、`product_shortname`(string,Raydo 短名,參考)
  - `shopify_carrier_name`(string,預設 `"Other"`)
  - `tracking_url_template`(string,預設 `https://t.17track.net/en#nums=#TrackingNumber#`,每渠道可改)

### Raydo API client
- 新 `RaydoService`(`app/services/raydo_service.rb`),比照 `shopify_service.rb`(HTTParty)。憑證/URL 來自 `logistics_account`。
- Phase 1 需要:
  - `authenticate`:`GET {url1_base}/selectAuth.htm?username=&password=` → `{customer_id, customer_userid, ack}`;成功則快取 `customer_id`/`customer_userid` 到 account。
  - `product_list`:`GET {url1_base}/getProductList.htm` → `[{product_id, product_shortname}]`。
- (Phase 2 再加 createOrderApi / postOrderApi / 打標籤 / 軌跡 / 取號。)
- 詳細 API 筆記見 `.plan/raydo_api_notes.md`。

### UI(放 Shipping 子選單)
- Shipping nav-group 新增子項「物流渠道」(gate 在 `logistics_channels` 權限;controller 加入 `shipping_active` 白名單 + `has_shipping_items` 條件)。
- **帳號設定頁**:填 `username`/`password` + `url1_base`/`url2_base`;一個「測試/認證」動作呼叫 `selectAuth`,成功則快取 `customer_id`/`customer_userid` 並提示成功。
- **渠道管理**:列表 + 新增/編輯/刪除。**新增流程**:呼叫 `getProductList` 從 Raydo 拉清單 → 下拉選 `{product_id — product_shortname}`;使用者選 `product_id`、填別稱、`shopify_carrier_name`(預設 Other)、`tracking_url_template`(預設 17track)。**不手動輸入 `product_id`**。

### 權限(新增 `logistics_channels`)
- `AVAILABLE_PERMISSIONS` 新增 `logistics_channels`;相關 controller 映射到它。

### 外部依賴
- 實作/測試 Raydo 拉清單需要**正式環境 URL1/URL2 + username/password**(使用者提供)。spec 可先寫,實作此步時帶入。

---

## 測試(維持 95%+ 覆蓋率)
- **Model**:report 欄位驗證(context 必填 4 項)、`customs_complete?`、`encrypts` 加密、logistics_account/channel 關聯與 unique 約束、tracking_url 預設值。
- **Request**:`products` 權限 gate(有/無)、報關批量更新的必填強制、`logistics_channels` 權限 gate、渠道 CRUD、帳號認證動作。
- **System**:Products nav-group 展開 + 報關頁 Turbo 互動(批量編輯);渠道新增下拉選取(需 stub Raydo)。
- **RaydoService**:外部 API 邊界 —— 比照專案對外部服務的處理,stub HTTP 邊界(WebMock 或 instance_double(RaydoService)),不打真實 Raydo。
- i18n:en / zh-TW / zh-CN 所有新標籤 + 兩個新權限的 label。

## 待釐清 / 風險
- `ProductVariantsController#update` 目前的 permit 與成本頁共用,擴充報關欄位時避免互相污染(成本頁 bulk_update 不應誤帶報關 context 驗證)。
- RaydoService 測試需要一組可用(或 stub)的認證回應;正式 URL/帳密由使用者提供。
- 打包模塊(Phase 2)才會真正「因缺報關而擋包裹推進」;Phase 1 的強制僅在報關編輯存檔時。
