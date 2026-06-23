# 統一 Store 切換組件 — 設計 Spec

- 日期:2026-06-23
- 分支:`feature/unified-store-switcher`
- 狀態:已與使用者確認 UX 方向

## 1. 背景與問題

App 已支援同一 Company 下多個 `ShopifyStore`,但 Dashboard / Orders / Shipments / Tickets 四大版塊**無法依店鋪分開查看數據**。

根因:目前店鋪篩選只靠 URL 參數 `?store_id=`(見 `AdminController#current_shopify_store`),**沒有持久化到 session**,一換頁就丟失;且 Dashboard **完全沒有**按 store 篩選(只按 group/company 計算)。

## 2. 目標

提供一個**統一、跨四大版塊一致**的 Store 切換組件,且:

- 需要看到「All(全部店鋪加總)」:**Dashboard、Shipments**
- 只需分店看、**不需要 All**:**Tickets、Orders**
- **Settings 不顯示**切換(Settings 是 Company/Department 級設定)
- 選擇**全站共用一個**、跨頁持久化(行為對齊既有的 Company / Department 切換)

非目標(YAGNI):多選店鋪、每店徽章數字、店鋪搜尋框、Settings 內的店鋪切換。

## 3. UX(已確認)

版面:每頁內容區頂部一行 `[ 標題 ][ 🏪 Store 切換 ] ……撐開…… [ 該頁操作按鈕 ]`。

- 切換組件**緊鄰標題右邊**;頁面既有操作(Orders 的 Sync Orders、Shipments 的 Export Excel / Sync 等)維持在**最右側**,兩者以 flex `justify-between` 分開。
- Dashboard / Shipments 下拉含 `✓ All Stores` + 各店鋪。
- Orders / Tickets 下拉**只有店鋪**、無 All。
- 公司只有一間可見店鋪時:**只顯示店名純文字、不顯示下拉**(對齊 Company switcher 單一公司行為)。
- Settings 各頁:**完全不 render** 此組件。

視覺沿用既有 Tailwind 灰階風格(白底、`border-gray-300`、`rounded-md`、`shadow-sm`),與 sidebar 的 company switcher 一致。

Remote preview:Claude Design 專案 `f733a0f5-ffff-4e9d-8da4-d7e0cc772a2d`。

## 4. 架構設計

### 4.1 後端:統一 store 選擇解析(`AdminController`)

新增「哪些 controller 允許 All / 顯示切換器」的政策,以 `controller_name` 判定:

```ruby
STORE_SWITCHER_CONTROLLERS = %w[dashboard orders shipments tickets].freeze
STORE_ALL_ALLOWED_CONTROLLERS = %w[dashboard shipments].freeze
```

新增 `before_action :persist_store_selection`(僅在上述 controllers 生效):

```ruby
def persist_store_selection
  return unless store_switcher_visible?
  session[:store_id] = params[:store_id] if params[:store_id].present?
end
```

- `params[:store_id]` 值域:`"all"` 或 store UUID。
- 不在切換器範圍的頁面(含 Settings)不寫 session,避免污染。

重寫 `current_shopify_store`,依「來源優先序 params → session」+「本版塊是否允許 All」解析,回傳 `ShopifyStore` 或 `nil`(`nil` 代表「全部店鋪」):

```ruby
def current_shopify_store
  @current_shopify_store ||= resolve_current_store
end

def resolve_current_store
  stores = visible_shopify_stores
  raw = params[:store_id].presence || session[:store_id].presence

  if raw == "all"
    return nil if store_all_allowed?      # Dashboard / Shipments:All = nil
    return stores.first                    # Orders / Tickets 不允許 All → 退回第一間(不覆寫 session)
  end

  if raw.present?
    found = stores.find_by(id: raw)
    return found if found                  # 有效具體店
  end

  # 未選 / 無效(已刪除 / 換 company 殘留)
  store_all_allowed? ? nil : stores.first
end
```

helper 方法(供 view 用,皆 `helper_method`):

```ruby
def store_switcher_visible?
  STORE_SWITCHER_CONTROLLERS.include?(controller_name)
end

def store_all_allowed?
  STORE_ALL_ALLOWED_CONTROLLERS.include?(controller_name)
end
```

換 company 時清掉殘留:在 `set_current_company` 偵測到 `session[:company_id]` 變動時 `session.delete(:store_id)`(對齊既有 `view_group_id` 的處理精神)。

`visible_shopify_stores` 沿用不動 → 自動套用 group / 權限可見範圍。

### 4.2 前端:統一組件

**Partial** `app/views/shared/_store_switcher.html.erb`:

- 讀 `visible_shopify_stores`、`current_shopify_store`、`store_all_allowed?`。
- 多於一間可見店鋪 → 渲染 `<select>`(每個 `<option>` value 為「帶新 `store_id` 的當前頁 URL」),`store_all_allowed?` 時最前面加 `All Stores` 選項(value 帶 `store_id=all`)。
- 恰一間 → 純文字顯示店名 + 🏪 icon。
- 零間 → 顯示 `t("store_switcher.no_stores")`。
- 樣式對齊 company switcher。

**Stimulus** `app/javascript/controllers/store_switcher_controller.js`:

- 仿 `company_switcher_controller.js`:`change` 時取 `<option>` value(已含完整目標 URL)→ `window.location` 導航(GET)。
- 保留當前頁既有 query(日期、`archived`、分頁等):option 的 URL 由 server 端用 `url_for(request.query_parameters.merge(store_id: ...))` 產生,確保保留。

**Layout 接入** `app/views/layouts/admin.html.erb`:在內容區頂部 `<% if store_switcher_visible? %>` 才 render header 行。但因切換器要與「各頁標題 + 操作按鈕」同一行,實作上採:提供一個共用 header 區塊,各頁把標題與操作按鈕透過既有 pattern 放入;切換器由共用 partial 注入標題右側。

> 實作細節(標題行如何組裝)留待 writing-plans 階段依各頁現況決定:
> 方案 A — layout 提供 `content_for(:page_title)` 與 `content_for(:page_actions)`,header 行在 layout 統一組裝並插入切換器;
> 方案 B — 各頁自行 render `shared/_store_switcher` 於標題右側。
> 預設採方案 A(最符合「統一組件」),writing-plans 時確認各頁 header 現況後定案。

**i18n**:`config/locales` 增 `store_switcher.all_stores`、`store_switcher.label`、`store_switcher.no_stores`(en / zh-CN / zh-TW)。

### 4.3 各版塊接上篩選

- **Orders**:`current_shopify_store` 現在對 Orders 恆為具體店(不允許 All),既有 `if current_shopify_store ... else 全部` 邏輯沿用即可,實務上走具體店分支。
- **Shipments**:沿用既有 `current_shopify_store`(具體店)vs `visible_shopify_stores`(All → nil)邏輯。
- **Tickets**:`visible_tickets` 收斂為「`current_shopify_store` 的 email accounts 之 tickets」(恆具體店):
  ```ruby
  def visible_tickets
    accounts = visible_email_accounts
    accounts = accounts.where(shopify_store_id: current_shopify_store.id) if current_shopify_store
    Ticket.where(email_account_id: accounts.select(:id))
  end
  ```
- **Dashboard**(改動最大):`DashboardMetricsService` 增加 `shopify_store:` 參數;
  - `current_shopify_store` 為 `nil` → 維持現有「整個 group/company 加總」。
  - 為具體店 → 指標只算該店(在既有 scope 上再 `where(shopify_store_id:)` / 透過 order 關聯收斂)。

## 5. 邊界處理

| 情況 | 行為 |
|------|------|
| 無任何可見店鋪 | 切換器顯示 `no_stores`;Orders/Tickets 走既有空狀態 |
| session 內 store 已被刪 / 換 company | `find_by` 找不到 → 視為未選,套各頁預設 |
| 換 company | 清 `session[:store_id]` |
| Orders/Tickets 目前選擇是 All | 顯示並查詢第一間店,**不覆寫 session**,Dashboard 仍記得 All |
| group 成員可見店受限 | 切換器只列可見店(沿用 `visible_shopify_stores`) |

## 6. 測試(需符合 95% 覆蓋)

- **Service spec**:`DashboardMetricsService` 加 `shopify_store:` 篩選的指標正確性(具體店 vs nil 加總)。
- **Request specs**(四 controller):
  - store 解析優先序(params > session)、session 持久化。
  - Dashboard/Shipments 的 All(nil)與具體店。
  - Orders/Tickets 不允許 All → 退回第一間且不覆寫 session。
  - 無效 / 已刪 store_id → 退回預設。
  - 換 company → 清除 `session[:store_id]`。
  - Settings 頁不寫 session、不顯示切換器。
- **System spec**:切換器在四頁出現、Settings 不出現;切換後資料變更;單店顯示店名無下拉;切換器與操作按鈕同行不重疊。

## 7. 影響檔案(預估)

- `app/controllers/admin_controller.rb`(解析 + helper + before_action)
- `app/controllers/dashboard_controller.rb`、`app/services/dashboard_metrics_service.rb`
- `app/controllers/tickets_controller.rb`(`visible_tickets`)
- `app/views/shared/_store_switcher.html.erb`(新)
- `app/views/layouts/admin.html.erb`(header 接入)
- 各頁 view(標題行調整,依方案 A/B)
- `app/javascript/controllers/store_switcher_controller.js`(新)
- `config/locales/*`(i18n)
- 對應 specs
