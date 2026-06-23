# Ad Campaigns — 統一 Store 切換組件 設計 Spec

- 日期:2026-06-23
- 分支:`feature/ad-campaigns-store-switcher`
- 前置:`feature/unified-store-switcher`(PR #165/#166 已上 staging + production)
- 狀態:已與使用者確認(完全統一)

## 1. 背景與問題

統一 Store 切換組件已上線於 Dashboard / Orders / Shipments / Tickets。Ad Campaigns 頁面**也有 store 篩選,但**:

- 用的是**自己一套**:`params[:shopify_store_id]` + `@selected_store`(`AdCampaignsController#index`),與共用組件的 `params[:store_id]` / `current_shopify_store`(session 持久化)不同。
- 放在 **filter 欄**裡(`@show_store_selector` 的 `<select>`),不在標題欄。
- store 選擇**不與其他頁同步**(沒有 session 共用)。

使用者要求:把它**完全統一**到共用組件、放標題欄,store 選擇全站共用。

## 2. 目標

- Ad Campaigns 使用共用 `shared/_store_switcher`,放在標題列(`[title][🏪 store_switcher] …… [動作]`)。
- store 選擇改用 `current_shopify_store`(session 持久化、全站共用);Ad Campaigns 屬**恆具體店**(無 All),與 Orders/Tickets 同政策。
- filter 區的 **ad account 子選單保留**,跟著選定 store;日期/狀態/排序不變。
- `group_view_switcher` 維持不動(group 是另一維度,與 Dashboard 一致)。

非目標(YAGNI):Ad Campaigns 加「All Stores」;改動 group_view_switcher;改 ad account / 日期 / 排序邏輯。

## 3. 架構設計

### 3.1 `AdminController`
把 `ad_campaigns` 加入 `STORE_SWITCHER_CONTROLLERS`(**不**加入 `STORE_ALL_ALLOWED_CONTROLLERS`)。如此:

- 標題列會 render 切換器(`store_switcher_visible?` 為真)。
- `current_shopify_store` 對 ad_campaigns 恆解析為具體店(無選擇 → 第一間可見店),且 `params[:store_id]` 會持久化進 session。

### 3.2 `AdCampaignsController#index`
- 移除舊的 store 解析:`params[:shopify_store_id]`、`@selected_store ||= @shopify_stores.first`、`@show_store_selector`、`@shopify_stores`(僅供舊 selector 用的部分)。
- 新:`@selected_store = current_shopify_store`。
- 保留 `view_scope = selected_view_group || current_company`;ad account 來源仍為 `view_scope.ad_accounts`,並以選定 store 收斂:
  ```ruby
  base_ad_accounts = view_scope.respond_to?(:ad_accounts) ? view_scope.ad_accounts : visible_ad_accounts
  @ad_accounts = if @selected_store
    base_ad_accounts.where(shopify_store: @selected_store).order(:account_name)
  else
    base_ad_accounts.order(:account_name)
  end
  ```
- `@selected_account` 邏輯不變:`params[:ad_account_id]` 找不到 → nil → 視圖顯示 "all accounts"。**這天然處理「換店後舊 account 失效」**(換店是整頁導航,新店若無該 account → 退回 all)。

### 3.3 `ad_campaigns/index.html.erb`
- 標題列改為 flex:`[h1 title][render "shared/store_switcher"] …… [既有右側動作(Sync 等)]`(對齊其他四頁的 Method B)。
- 移除 filter 區的 store `<select>` / hidden `shopify_store_id` 整塊(`@show_store_selector` 區塊)。
- 保留 ad account 子選單、日期、狀態、排序、欄位設定。
- `group_view_switcher` 保留。

### 3.4 `campaign_filter_controller.js`
- 移除 `storeSelect` target 與 `storeChanged()`(store 改由 `store_switcher` 導航,不再經此表單)。其餘 target/方法不動。

### 3.5 換店時的參數保留
共用 `store_switcher` 以 `url_for(path_params.merge(query_params.merge(store_id: ...)))` 導航,會保留目前 query(日期、狀態、ad_account_id)。`ad_account_id` 若不屬新店 → controller 解析為 nil → 顯示 all accounts(可接受,無需特別清除)。

## 4. 邊界處理

| 情況 | 行為 |
|------|------|
| 無選擇 | `current_shopify_store` = 第一間可見店(恆具體店) |
| owner 同時選 view group 又選不屬該 group 的 store | `@ad_accounts` 為空(view_scope ∩ store),與 Dashboard 的 group+store 交集行為一致,可接受 |
| 單一可見店 | 共用組件顯示店名純文字、無下拉(與其他頁一致) |
| 換店帶著舊 ad_account_id | controller 找不到 → all accounts |

## 5. 測試(維持 95% 覆蓋)

- **Request spec(`ad_campaigns_spec`)**:
  - 既有用 `shopify_store_id` 的例子改為 `store_id`。
  - 標題列出現切換器(多店時);選 store 後 campaigns/ad accounts 正確收斂。
  - store 選擇經 session 持久化(無 param 時沿用 session)。
  - 單店時不顯示下拉(顯示店名)。
- **既有 spec 更新**:任何依賴 `shopify_store_id` 或 filter 區 store `<select>` 的斷言改為新行為。
- 全套 + system 綠燈;RuboCop 0;Brakeman 0;bundler-audit clean。

## 6. 影響檔案

- `app/controllers/admin_controller.rb`(常數加 `ad_campaigns`)
- `app/controllers/ad_campaigns_controller.rb`(store 解析改 `current_shopify_store`)
- `app/views/ad_campaigns/index.html.erb`(標題列 + 移除 filter store 區塊)
- `app/javascript/controllers/campaign_filter_controller.js`(移除 storeChanged/storeSelect)
- `spec/requests/ad_campaigns_spec.rb`(+ 其他引用 shopify_store_id 的 spec)
