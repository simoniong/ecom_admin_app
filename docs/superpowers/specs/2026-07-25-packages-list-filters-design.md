# 打包模組列表：篩選、排序與批量審核

日期：2026-07-25
分支：`feature/packing-review-filters`
狀態：設計已確認，待實作

## 1. 背景

打包模組的「待審核」列表（`PackagesController#index`）目前只有兩個維度：側邊欄的狀態切換，以及 `applying_tracking` 狀態下的申請狀態子分頁。實際作業時缺三件事：

1. **無法跨店鋪檢視。** `packages` 在 `STORE_SWITCHER_CONTROLLERS` 內但不在 `STORE_ALL_ALLOWED_CONTROLLERS`（`app/controllers/admin_controller.rb:28-29`），所以頂部切換器不提供「全部」，一次只能看一間店。
2. **無法依國家篩選、無法排序。** 列表固定 `order(created_at: :desc)`（`app/controllers/packages_controller.rb:25`）。
3. **待審核沒有批量操作。** `index.html.erb:22` 的 `bulk` 旗標只涵蓋 `pending_process` 與 `pending_label`，審核只能逐筆點進 modal 處理。

## 2. 目標與非目標

**目標**

- 店鋪維度可切「全部 / 個別店鋪」。
- 國家區域篩選。
- 依建包時間 / 下單時間 / 付款時間排序，可切升降序。
- 待審核列表支援批量審核。

**非目標（本次不做）**

- 截圖參考來源的其他篩選維度：平台渠道、訂單規則、SKU 搜尋、金額排序、儲存篩選組合。
- 「批量操作」「批量採購」等其他批量動作。
- 匯入／匯出。

## 3. 店鋪篩選

把 `"packages"` 加入 `AdminController::STORE_ALL_ALLOWED_CONTROLLERS`。頂部既有的店鋪切換器隨即提供「全部」選項；`PackagesController#scoped_packages`（`packages_controller.rb:483`）本來就在 `current_shopify_store` 為 `nil` 時退回 `visible_shopify_stores`，不需修改。

**行為變更（已與使用者確認接受）：** `resolve_current_store` 的收尾是 `store_all_allowed? ? nil : stores.first`（`admin_controller.rb:183`），因此在沒有 `store_id` 參數也沒有 session 值時，打包頁的預設從「第一間店」變成「全部店鋪」。此變更同時影響打包模組的所有狀態頁，非僅待審核頁。

跨店鋪檢視時，列表需要能分辨每筆屬於哪間店：`_package_row` 增加店鋪名稱顯示（僅在 `current_shopify_store` 為 nil 時渲染該欄，避免單店模式下多一欄冗餘）。

## 4. 國家篩選

**參數：** `country`，ISO alpha-2 大寫。

**取值來源。** 列表顯示的國家取自 package 的地址快照，缺值時退回訂單的 Shopify 原始地址（`_package_row.html.erb:38-39`）。篩選必須用同一個運算式，否則會出現「列表顯示美國、但點美國篩不到」的矛盾。定義一段共用 SQL：

```sql
COALESCE(
  NULLIF(packages.shipping_address_snapshot->>'country_code', ''),
  NULLIF(orders.shopify_data->'shipping_address'->>'country_code', '')
)
```

`packages.order` 是 `belongs_to`（必填、無 optional），`joins(:order)` 為 inner join，不會漏掉任何 package，因此查詢一律 join，不做條件式 join。

**可選清單。** 對「目前狀態 + 目前店鋪範圍」的集合取 distinct，濾掉空值，依國家中文名（`parcel_country_name`）排序。不顯示筆數。

**白名單。** 傳入的 `country` 必須出現在該清單中，否則忽略（視同全部）。清單本身來自 DB 的 distinct 結果，因此篩選值永遠是被驗證過的字串，不會有注入面。

**UI。** 表格上方篩選列的第一行「國家區域」：`全部` 膠囊 + 各國膠囊（國旗 emoji + 中文名，沿用 `parcel_country_flag` / `parcel_country_name`）。選中者高亮。每個膠囊是保留其他查詢參數的連結，並重設 `page`。

**效能。** 該運算式無索引，會是順序掃描。單店的 packages 量級（數千）可接受。若日後成為瓶頸，補一個 `packages.shipping_address_snapshot->>'country_code'` 的表達式索引即可；本次不預先加。

## 5. 排序

**參數：** 沿用訂單頁的既有命名（`OrdersController::SORTABLE_COLUMNS`、`orders/index.html.erb:157`），使用 `sort_column` 與 `sort_direction`，避免同一個 app 兩套排序參數。

| `sort_column` | 排序欄位 | 說明 |
|---|---|---|
| `created_at`（預設） | `packages.created_at` | 建包時間，維持現行行為 |
| `ordered_at` | `orders.ordered_at` | 下單時間 |
| `paid_at` | `orders.paid_at` | 付款時間，見第 6 節 |

`sort_direction` ∈ `asc` / `desc`，預設 `desc`。無效值一律退回預設，不報錯。

**空值處理。** `ordered_at` / `paid_at` 可能為 NULL（舊資料、非 Shopify 來源）。兩個方向都用 `NULLS LAST`，避免升序時整頁被空值佔滿。

**分頁穩定性。** 現行 `order(created_at: :desc)` 沒有 tie-breaker，時間戳相同的多筆記錄在翻頁時可能重複或漏掉。所有排序都追加 `packages.id` 作為次要鍵（方向與主鍵一致）。這順帶修掉一個既有的潛在缺陷。

**SQL 安全。** `sort_column` 與 `sort_direction` 都先映射成常數表中的固定字串再組裝，使用者輸入永遠不會直接進入 `Arel.sql`。

**UI。** 篩選列第二行「排序方式」：三個切換項（按建包時間 / 按下單時間 / 按付款時間）。點擊非當前項切換欄位並用預設 `desc`；點擊當前項切換升降序。當前項顯示 ▲ / ▼。以連結實作（保留其他參數、重設 `page`），不需要 Stimulus。

## 6. `orders.paid_at` 新欄位

Shopify 訂單沒有獨立的「付款時間」欄位，最接近的是 REST payload 的 `processed_at`（付款處理時間）。目前它只存在 `orders.shopify_data` JSON 裡，無法有效率地排序。

**Migration**

- `add_column :orders, :paid_at, :datetime`
- `add_index :orders, [:shopify_store_id, :paid_at]`（對齊既有的 `idx_orders_store_ordered_at`）
- 回填：`UPDATE orders SET paid_at = (shopify_data->>'processed_at')::timestamptz WHERE shopify_data->>'processed_at' ~ '^\d{4}-\d{2}-\d{2}'`。加上正則守衛，避免任何非預期字串讓整個 migration 失敗。

**寫入點**（兩處都要補，否則不同同步路徑會產生不一致的資料）

- `app/services/sync_all_orders_service.rb:90` 的 `attrs`
- `app/services/shopify_lookup_service.rb:62` 的屬性組

兩處都寫成 `paid_at: shopify_order["processed_at"]`，無條件寫入。不依 `financial_status` 條件式寫入——那會在退款等狀態變動時讓欄位在「有值 / 變回 nil」之間漂移。打包模組本來就只對 `paid` / `partially_paid` 訂單建包（`package_auto_builder.rb:4`），所以出現在此列表的訂單必然已付款。

`Order` model 上以註解記錄「`paid_at` 來自 Shopify `processed_at`」，避免後人誤以為它來自交易紀錄。

## 7. 批量審核

**路由：** `post :submit_review_bulk, on: :collection`（`resources :packages` 的 collection 區塊，與既有的 `apply_tracking_bulk` / `ship_bulk` 並列）。

**Action。** 完全沿用 `apply_tracking_bulk`（`packages_controller.rb:252`）與 `ship_bulk` 已建立的模式：

- 權限閘 `current_membership&.package_review?`（審核走 `package_review`，與 `REVIEW_EVENTS` 的授權一致，見 `authorized_for_event?`）。
- 候選集合 `scoped_packages.where(id: ids, aasm_state: "pending_review")` —— 同時提供跨公司隔離與狀態守衛。
- 逐筆 `rescue AASM::InvalidTransition, ActiveRecord::ActiveRecordError`，記入 `skipped` 並 `Rails.logger.warn`，不中斷整批（處理查詢與轉換之間的競態）。
- 結束後 redirect 回列表，flash 顯示 `reviewed` / `skipped` 筆數。

**篩選保留。** 表單以 `submit_review_bulk_packages_path(country:, sort_column:, sort_direction:)` 作為 action，redirect 時把這些參數帶回 `packages_path`，批量操作後不會把使用者的篩選條件洗掉。同樣的處理套用到既有的 `apply_tracking_bulk` 與 `ship_bulk` redirect（它們現在寫死 `packages_path(state: ...)`），否則在其他狀態頁用批量功能一樣會掉篩選。

**View。** `index.html.erb:22` 的 `bulk` 條件加入 `pending_review`，`bulk_url` / `bulk_label` 依狀態分派；重用現成的 `package_bulk` Stimulus controller 與全選勾選框，不新增 JS。

## 8. 程式碼組織

新增 `app/services/package_list_query.rb`（放在 `app/services`，與 `PackageSplitter`、`PackageLabelPrinter`、`PackageAutoBuilder` 同慣例；本專案沒有 `app/queries`）。

`PackagesController` 目前 487 行，`index` 只有 12 行；把篩選與排序組裝塞進 controller 會讓它再長一截，而且只能透過 request spec 間接測試。查詢物件把這段邏輯關進一個可獨立測試的單元。

```ruby
PackageListQuery.new(scope, country:, sort_column:, sort_direction:)
```

- `scope` —— 已套好公司/店鋪範圍與 `aasm_state` 的 relation，由 controller 傳入。查詢物件不碰授權範圍。
- `#countries` —— 該範圍內出現過的國家代碼，已排序。
- `#country` / `#sort_column` / `#sort_direction` —— 正規化後的值，供 view 標示當前選中項。
- `#relation` —— 套好 join、篩選與排序的 relation。分頁仍由 controller 負責（沿用現行寫法）。

Controller `index` 因此維持精簡：解析 state → 組 scope → 交給查詢物件 → 分頁。

## 9. 列表呈現調整

- 「建包時間」欄改為「時間」欄，兩行顯示：`下單：YYYY-MM-DD HH:MM` / `付款：YYYY-MM-DD HH:MM`，缺值顯示 `—`。
- 建包時間讓出列表版面後仍需有地方可查：在詳情 modal 的 `_order_info` 區塊新增一列顯示（該 partial 目前沒有任何時間欄位，這是新增而非搬移）。「按建包時間」仍是排序選項且是預設值——雖然列表不再有這一欄，排序列會明確標示當前排序依據，不會造成「照著看不見的欄位排序」的困惑。
- 時間一律以店鋪時區呈現，與訂單頁（`orders/index.html.erb:247`）一致。這裡取 `package.shopify_store.active_timezone`，而非訂單頁用的 `order.shopify_store&.active_timezone` —— `packages.shopify_store_id` 有 NOT NULL 約束、`orders.shopify_store_id` 沒有，且 `shopify_store` 已在 `index` 的 `includes` 中預載，不會多打 query。這是**修正**：現行 `_package_row.html.erb:47` 直接 `strftime` 輸出 UTC，與訂單頁對同一筆訂單顯示的時間不一致。
- 跨店鋪模式（`current_shopify_store` 為 nil）時多顯示一欄店鋪名稱。
- 三個 i18n 檔（`zh-TW` / `zh-CN` / `en`）同步補齊新增文案。

## 10. 測試計畫

專案要求 95% 行覆蓋率、RSpec + FactoryBot、不使用 mock。

**`spec/services/package_list_query_spec.rb`**
- 國家篩選：命中快照的國家；快照缺值時退回訂單 JSON 的國家；不在清單內的值被忽略。
- `#countries`：只回傳範圍內出現過的國家、去重、排序。
- 三種排序 × 升降序的實際順序。
- `NULLS LAST`：`paid_at` 為 nil 的記錄在升序時排在最後。
- tie-breaker：時間戳相同時順序穩定。

**`spec/requests/packages_spec.rb`（擴充）**
- 各篩選/排序參數的組合；無效 `country` / `sort_column` / `sort_direction` 退回預設而非 500。
- 跨店鋪模式只回傳可見店鋪的 package（沿用既有的隔離測試模式）。
- `submit_review_bulk`：成功轉換並計數；無 `package_review` 權限被擋；非 `pending_review` 的 id 被跳過；他公司的 id 被跳過；redirect 保留篩選參數。

**`spec/system/packages_spec.rb`（擴充）**
- 點國家膠囊後列表收斂。
- 點排序項切換欄位、再點一次切換升降序。
- 勾選數筆後按「批量審核」，列表清空並顯示 flash。

**`spec/models/order_spec.rb` / 同步服務 spec**
- 同步時 `paid_at` 由 `processed_at` 寫入；`processed_at` 缺值時為 nil。

## 11. 風險

- **預設店鋪範圍變更**（第 3 節）是使用者可感知的行為變化，已確認接受。
- **回填 migration** 會掃描整張 orders 表。以目前資料量（單一 VPS、單一公司）不需分批；若日後資料量成長，需改為分批回填。
- **國家篩選無索引**（第 4 節），已評估為可接受，並記錄了後續補索引的路徑。
