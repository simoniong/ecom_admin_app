# Shopify Per-Store Credentials — 設計文件

**日期**：2026-05-14
**Branch**：`feature/shopify-per-store-credentials`
**Target**：`staging`

## 背景與目標

目前 Shopify 店家連接靠單一全域 app 的 `SHOPIFY_CLIENT_ID` / `SHOPIFY_CLIENT_SECRET`（ENV）。這個模式走不通：

- Partner 公開發布（public distribution）需要上 App Store + 通過審核
- Custom distribution 只能裝在單一 store 或同一個 Plus organization —— 實測兩個不同 org 的店家無法共用一個 app
- Shopify admin 自建 custom app 已不能新建

本系統的使用者都是熟人，可接受讓每個 merchant 在自己的 dev 帳號建一個 app（custom distribution 到自己的店、不需審核）。本設計把 `client_id` / `client_secret` 從全域改成 **per-store**，讓每家店用自己 app 的憑證走標準 OAuth。

## 非目標

- 不做 public distribution / App Store 上架
- 不做 Shopify Billing API（custom distribution 本來就不支援）
- 不改 OAuth 流程結構（authorization code grant 不變）
- 不做 `ShopifyStore` 軟刪除

## 連接流程（已確認：Flow A）

系統表單輸入 + 系統發起 OAuth：

1. 使用者在 `shopify_stores` 頁面表單填 `shop_domain` + `client_id` + `client_secret`（+ group，如果公司有 groups）
2. 送出 → `ShopifyOauthController#auth` 把憑證存進 session（pending state），用傳入的 `client_id` 組 authorize URL，redirect 到 Shopify
3. merchant 在 Shopify 授權
4. Shopify redirect 回 `#callback` → 從 session 讀回憑證 → 驗 HMAC + state → 用憑證換 token
5. 原子地建立 `ShopifyStore`，把 `client_id` / `client_secret` / `access_token` 一起寫入
6. 清掉 session 的 pending 值

首次連接與 reauth 流程相同（callback 用 `find_or_initialize_by(shop_domain:)` 處理新建或更新），所以共用同一個表單。

## 資料層

### Migration（單一 migration）

`db/migrate/<timestamp>_add_credentials_to_shopify_stores.rb`：

1. `add_column :shopify_stores, :client_id, :string`（nullable）
2. `add_column :shopify_stores, :client_secret, :text`（nullable）
3. 在同一個 migration 內用 `ShopifyStore` model 逐筆回填現有店家：
   - 讀 `ENV["SHOPIFY_CLIENT_ID"]` / `ENV["SHOPIFY_CLIENT_SECRET"]`（migration 執行時可讀）
   - 若任一為空 → `raise` 中止 migration（避免留下半套資料）
   - `ShopifyStore.reset_column_information` 後 `find_each`，逐筆 `update!(client_id:, client_secret:)`
   - **必須走 model 更新**，`update_all` 會繞過 `encrypts` 導致 `client_secret` 明文落地

不加 `null: false`：回填依賴 ENV，部分環境可能未設；改用 model validation 保證新資料完整。

> 註：一般不建議在 migration 引用 application model，但此處回填邏輯極簡單（複製 ENV 值）且為一次性操作，可接受。

### Model — `ShopifyStore`

```ruby
encrypts :access_token, deterministic: false
encrypts :client_secret, deterministic: false

validates :client_id, presence: true
validates :client_secret, presence: true
```

其餘關聯、validation 不變。

## Controller — `ShopifyOauthController`

### `#auth`

- 從 params 收 `shop` + `client_id` + `client_secret`
- 驗證：`shop` 符合 `SHOP_DOMAIN_FORMAT`（已有）；`client_id`、`client_secret` 皆 present —— 任一不符 → redirect 回 `shopify_stores_path` 帶 alert
- group 邏輯不變（`company_has_groups?` → `pending_binding_group_id` 存 session）
- 產生 nonce 存 `session[:shopify_oauth_nonce]`（已有）
- **新增**：`session[:shopify_pending_client_id]`、`session[:shopify_pending_client_secret]`、`session[:shopify_pending_shop]`
- 用**傳入的 `client_id`**（非 ENV）組 authorize URL
- scopes 維持現有字串：`read_products,read_customers,read_all_orders,read_fulfillments,read_analytics,write_webhooks`
- `redirect_uri` 維持 `shopify_callback_url(locale: nil)`

### `#callback`

- 從 session 讀回 `client_id` / `client_secret` / `shop`（取代 ENV）
- **若 session 缺 pending 值**（過期、直接點舊連結）→ redirect 回 `shopify_stores_path` 帶 `t("shopify_stores.oauth_failure")`，並清掉殘留 session 值
- 驗證 callback 的 `shop` param 與 session 的 `shop` 一致；不一致 → redirect 帶 alert
- HMAC 驗證（`verify_hmac`）改用 session 的 `client_secret`
- state/nonce 驗證不變
- `exchange_code_for_token` 改用 session 的 `client_id` / `client_secret`
- 建立 `ShopifyStore` 時把 `client_id`、`client_secret` 一起 `assign_attributes`（連同現有的 `access_token`、`scopes`、`timezone`、`installed_at`）
- 成功後清掉 `session[:shopify_pending_client_id]` 等所有 pending 值
- 其餘不變：`SyncAllShopifyOrdersJob`、`RegisterShopifyWebhooksJob`、`BackfillShopifyMetricsJob`

### 私有方法

- `verify_hmac(hmac, query_params, client_secret)` —— 新增 `client_secret` 參數，不再讀 ENV
- `exchange_code_for_token(shop, code, client_id, client_secret)` —— 新增憑證參數，不再讀 ENV
- 移除所有 `ENV["SHOPIFY_CLIENT_ID"]` / `ENV["SHOPIFY_CLIENT_SECRET"]` / `Rails.application.credentials.dig(:shopify, ...)` 的讀取

## Controller — `ShopifyWebhooksController`

### before_action 與 `#receive` 的分工

目前 `#verify_shopify_webhook`（before_action）用全域 secret 驗所有 webhook，`#receive` 再自己 `find_by(shop_domain:)` 處理 unknown shop。改版後維持這個分工，但 before_action 改成 per-store：

**`#verify_shopify_webhook`（before_action）**：
1. 從 `X-Shopify-Shop-Domain` header 取 shop domain
2. `ShopifyStore.find_by(shop_domain:)`，結果存入 `@webhook_store`（instance variable，供 `#receive` 重用，避免重複 query）
3. **找到店**：用 `@webhook_store.client_secret` 驗 HMAC；驗不過 → `head :unauthorized`（中止 action）
4. **找不到店**：跳過 HMAC 驗證，**不中止**，讓 `#receive` 繼續執行

用 header 來「選」secret 是安全的：偽造者若冒用任何店名，HMAC 對不上那家店的 `client_secret` 就會 fail。找不到店時跳過 HMAC 也是安全的：找不到店的 webhook 沒有可操作的對象，偽造它無害。

**`#receive`**：
- 改用 before_action 已查好的 `@webhook_store`（取代原本自己呼叫的 `ShopifyStore.find_by`）
- `@webhook_store` 存在 → 依 topic 正常處理（enqueue job）
- `@webhook_store` 為 nil（unknown shop）：
  - GDPR topics（`customers/data_request`、`customers/redact`、`shop/redact`）：記 log，`head :ok`（Shopify 要求 GDPR webhook 一定回 200，否則無限重試）
  - 其他 topics：記 log，`head :not_found`
  - 兩者都不執行任何副作用（不 enqueue job）

`#receive` 對 unknown shop 的處理邏輯與現狀基本一致，差別只在：現在「找不到店」也會先通過 HMAC（全域 secret），改版後「找不到店」直接跳過 HMAC。

## UI / View

### `shopify_stores/index.html.erb`

移除現有的「Partner link 首次安裝」資訊卡與獨立的 reauth 表單，改成：

**單一「連接店家」表單**，欄位：
- `shop_domain`（text，placeholder `your-store.myshopify.com`）
- `client_id`（text）
- `client_secret`（password type）
- group 選擇（沿用現有 `company_has_groups?` 邏輯）
- 送出 → `GET shopify_auth_path`（沿用現有 route）

**Merchant 設定指引**：表單上方放一段折疊式（`<details>`）說明，內容：
1. 到自己的 Shopify dev dashboard 建一個 app
2. Allowed redirection URL(s) 填 `<本系統網域>/shopify/callback`
3. API scopes 勾：`read_products,read_customers,read_all_orders,read_fulfillments,read_analytics,write_webhooks`
4. Distribution 選 custom，目標選自己的店
5. 複製 client_id / client_secret 貼到下方表單

### i18n

新增/改寫 `shopify_stores` 區塊字串於 `en.yml`、`zh-TW.yml`、`zh-CN.yml`：
- 表單三個欄位的 label
- 折疊指引的標題與各步驟文字
- 既有 key（`oauth_failure`、`bind_failure`、`bind_success`、`already_bound` 等）保留
- 移除不再使用的 key（`first_install_title`、`first_install_description`、`reauth_title`、`reauth_description`、`reauth_button` 等）

## 錯誤處理彙整

| 情況 | 行為 |
|---|---|
| `#auth` 缺 client_id / client_secret | redirect 回 `shopify_stores_path` 帶 alert |
| `#auth` shop domain 格式錯 | redirect 帶 alert（現有行為） |
| `#callback` session 缺 pending 值 | redirect 帶 `oauth_failure`，清殘留 session |
| `#callback` shop param 與 session 不符 | redirect 帶 alert |
| `#callback` HMAC / state 驗證失敗 | redirect 帶 `oauth_failure`（現有行為） |
| `#callback` 換 token 失敗 | redirect 帶 `bind_failure`（現有行為） |
| `#callback` store 存檔失敗（重複 shop_domain 等） | redirect 帶 `already_bound` / `bind_failure`（現有行為） |
| webhook 找到店、HMAC 失敗 | `head :unauthorized` |
| webhook 找不到店、GDPR topic | log + `head :ok`，無副作用 |
| webhook 找不到店、其他 topic | log + `head :not_found`，無副作用 |
| migration 執行時 ENV 未設 | `raise`，中止 migration |

## 測試

依專案慣例 RSpec + FactoryBot，無 mock DB，外部 Shopify HTTP 呼叫用 WebMock stub。維持 95%+ 行覆蓋率。

### `spec/models/shopify_store_spec.rb`
- `client_id` presence validation
- `client_secret` presence validation
- `client_secret` 加密（寫入後 DB 原始值非明文）

### `spec/factories/shopify_stores.rb`
- factory 加 `client_id` / `client_secret` 預設值

### `spec/requests/shopify_oauth_spec.rb`
- `#auth`：帶三欄位 → authorize URL 含傳入的 client_id、session 存了 pending 憑證
- `#auth`：缺 client_id 或 client_secret → redirect 帶 alert
- `#callback`：session 有 pending 值 → 用 session 憑證換 token、建立的 store 寫入了 client_id/secret
- `#callback`：session 缺 pending 值 → redirect 帶 oauth_failure
- `#callback`：shop param 與 session 不符 → redirect 帶 alert
- `#callback`：HMAC 用 session client_secret 驗證（正確/錯誤各一）

### `spec/requests/shopify_webhooks_spec.rb`
- 已知店、正確 HMAC（用該店 client_secret）→ 正常處理、enqueue job
- 已知店、錯誤 HMAC → `head :unauthorized`
- 未知店、GDPR topic → `head :ok`、不 enqueue job
- 未知店、非 GDPR topic → `head :not_found`、不 enqueue job

### Migration 回填
- `spec/migrations/` 或一支整合 spec：建立預先存在的 store（無 credentials）→ 跑回填 → store 有正確的、已加密的 client_id/secret
- ENV 未設時回填邏輯 raise

### `spec/system/shopify_stores_spec.rb`
- 連接表單渲染三個欄位 + 折疊指引
- 填表送出 → 導向 Shopify authorize URL（stub 外部）

## Git Workflow

從 `origin/staging` 切 `feature/shopify-per-store-credentials`（已完成），PR 到 `staging`。

## 部署順序

1. Migration（含回填）跑在 deploy 流程中 —— 需確認 deploy 環境的 `SHOPIFY_CLIENT_ID` / `SHOPIFY_CLIENT_SECRET` ENV 仍存在
2. Deploy 後，全域 ENV 變數已無程式碼引用，可從環境設定移除
3. 之後新店家走 per-store 表單流程

## 風險與緩解

| 風險 | 緩解 |
|---|---|
| Migration 回填時 `update_all` 繞過加密 | 設計明確要求走 model 逐筆 `update!`；測試驗證 DB 原始值非明文 |
| 部署環境 ENV 已被移除導致回填失敗 | Migration 在 ENV 缺失時 raise；部署順序要求先 deploy 再移除 ENV |
| `client_secret` 在 session cookie 中傳遞 | Rails session cookie 預設加密簽章；僅在 OAuth 往返約 30 秒內存在；callback 成功即清除 |
| merchant 設定的 scopes 與系統需要不符 | 指引明列必要 scopes；callback 後 `access_token_response["scope"]` 已存入 `store.scopes`，未來可加檢查（本期不做，YAGNI） |
| merchant 的 app 拿不到 `read_all_orders`（受保護 scope） | 設計範圍外的外部依賴；建議實作前先用一個朋友的店實測（已於討論中提醒） |

## 範圍外（未來）

- 連接後驗證 granted scopes 是否齊全並提示
- `read_all_orders` 受保護 scope 的申請流程
- `ShopifyStore` 軟刪除以保留 webhook 驗證能力
