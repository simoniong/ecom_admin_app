# 打包列表：店鋪 pill 篩選與 SKU 縮圖

日期：2026-07-26
分支：`feature/packing-store-pills-and-thumbnails`
狀態：設計已確認，待實作

## 1. 背景

打包列表目前的店鋪範圍由頂部的全域切換器決定，選擇會寫進 `session[:store_id]`。這帶來兩個問題：

1. **與頁面內的其他篩選不一致。** 國家與排序都是頁面內的 pill、走 URL 參數；店鋪卻是頁面外的下拉、走 session。同一排篩選條件分屬兩套機制。
2. **會影響其他頁面。** `session[:store_id]` 由所有 `STORE_SWITCHER_CONTROLLERS` 共用。在打包頁選「全部」會把 `"all"` 寫進 session，回到不允許「全部」的訂單頁時，它 fallback 到「第一間店」，使用者原本選的店鋪被換掉。這在 PR #227 的最終審查中就被指出過，當時決定不在該分支處理。

同時，列表的商品欄只有 SKU 文字。這批商品是畫作，操作員靠圖辨識遠比靠 SKU 快。

## 2. 目標與非目標

**目標**

- 店鋪篩選改為頁面內的 pill（全部 + 各店鋪名），走 URL 參數，不碰 session。
- 移除列表的店鋪欄。
- 每個 SKU 顯示縮圖，hover 顯示約 400px 的大圖。

**非目標**

- 不改其他頁面的店鋪切換機制。`session[:store_id]` 對 dashboard / orders / shipments / tickets / ad_campaigns 的行為完全不動。
- 不建立商品圖片的本地快取或代理，直接引用 Shopify CDN。
- 不處理 variant 層級的圖片。Shopify 的 variant 可以有自己的圖，但本設計取 product 層級的 `image_url`——這批商品每個畫作是一個獨立 product，framed/unframed 只是同一畫作的 variant，共用同一張圖是正確的。

## 3. 店鋪 pill

**參數名為 `store`，不是 `store_id`。** 這不是隨意取名：`AdminController#persist_store_selection` 是一個 before_action，看到 `params[:store_id]` 就會寫進 `session[:store_id]`。沿用 `store_id` 會讓「不碰 session」這個目標從一開始就不成立。

**`packages` 從 `STORE_SWITCHER_CONTROLLERS` 移除。** 頂部下拉在打包頁不再渲染，`persist_store_selection` 也因為 `store_switcher_visible?` 為 false 而直接 return。整頁只剩 pill 一套店鋪控制。

**新增 `PackagesController#selected_store`**（private + helper_method）：

```ruby
visible_shopify_stores.find_by(id: params[:store])
```

無效 id、他公司的 id、或未帶參數一律得到 `nil`，語意是「全部可見店鋪」。跨公司與跨群組隔離由 `visible_shopify_stores` 保證，與現行 `scoped_packages` 相同。

**連鎖影響——這是本節真正的工作量。** 打包頁目前有四處讀 `current_shopify_store`：

| 位置 | 用途 |
|---|---|
| `packages_controller.rb:48`（`sync`） | 決定同步哪些店鋪的訂單 |
| `packages_controller.rb:569`（`scoped_packages`） | 列表的店鋪範圍 |
| `index.html.erb:59, 75` | 店鋪欄的 `<th>` 與空狀態 colspan |
| `_package_row.html.erb:10, 84` | 店鋪欄的 `<td>`、時區縮寫的顯示條件 |

一旦 `packages` 離開 `STORE_SWITCHER_CONTROLLERS`，`resolve_current_store` 會改走 `unless store_switcher_visible?` 那條分支，語意不再是原本的樣子。**四處必須全部改用 `selected_store`，不能留一處混用**——混用會產生「pill 選了 A 店，但某個判斷仍看著另一個值」這種只在特定組合下出現的錯誤。

**UI。** 篩選列最上方新增一行「店鋪」，與國家、排序同樣的 pill 樣式：`全部` + 各店鋪的 `display_name`（不是 `name`——後者在未同步店名時為 nil）。只有一間可見店鋪時整行不渲染，一個永遠只有單一選項的篩選器只是雜訊。

## 4. 移除列表店鋪欄

移除 `index.html.erb` 的 `<th>` 與 `_package_row.html.erb` 的 `<td>`，空狀態 colspan 對應減一。

時區縮寫的顯示條件從「是否為全部店鋪」改為同樣的判斷，只是資料來源換成 `selected_store`——語意不變：跨店鋪檢視時附上時區縮寫，因為不同店鋪的當地時間並排會看起來像沒排好。

**取捨（使用者已知悉並確認）**：移除後，「全部」模式下無法從列上分辨該筆屬於哪個店鋪。

## 5. SKU 縮圖與 hover 大圖

**資料路徑**：`package_item.product_variant&.product&.image_url`。`package_items.product_variant_id` 可為 null，`products.image_url` 也可能為空，兩者都要能安然落到佔位方塊。

**Eager load**：`index` 現行的 `includes(:order, :package_items, :shopify_store, :logistics_channel)` 改為 `includes(:order, :shopify_store, :logistics_channel, package_items: { product_variant: :product })`。不改的話每個 SKU 兩次查詢，50 列可以輕鬆變成上百次。

**必須用 Shopify CDN 的尺寸參數。** 列表最多 50 列、每列數個 SKU，原圖各數百 KB，直接引用原圖是數十 MB 的下載。Shopify CDN 的慣例是在副檔名前插入尺寸：

```
.../files/painting.jpg?v=123  →  .../files/painting_100x100.jpg?v=123
```

新增 helper `shopify_image_variant(url, size)`：

- 只在 URL 的路徑部分符合「有可辨識副檔名」時轉換（`.jpg` / `.jpeg` / `.png` / `.webp` / `.gif`，不分大小寫）。
- 保留 query string（`?v=` 是 Shopify 的快取破壞參數，丟掉會拿到過期圖）。
- 不符合格式時**原樣回傳**。對非預期的 URL 格式硬套規則，結果是壞掉的圖片連結而不是原圖。
- `nil` / 空字串回傳 `nil`。

縮圖取 `100x100`（2 倍於 48px 的顯示尺寸，供高解析螢幕用），大圖取 `400x400`。

**大圖不能用純 CSS。** 表格外層是 `<div class="overflow-x-auto">`，`absolute` 定位的彈出層會被這個容器裁掉。需要一個 Stimulus controller `image-preview`：`mouseenter` 時把一個 `fixed` 定位的預覽層掛到 `document.body`（脫離表格的 overflow 脈絡），依游標位置擺放並自動避開視窗邊緣；`mouseleave` 移除。整個 app 只需要一個預覽層節點，重複使用。

**缺圖**：同尺寸的灰色佔位方塊，不掛 hover 行為。列高因此一致，且一眼看得出哪些 SKU 還沒同步到圖。

**這個功能依賴商品同步。** `products.image_url` 只在店鋪跑過「同步商品」後才有值。沒同步過的店鋪會整排顯示佔位方塊——功能本身沒壞，但要先跑同步才看得到圖。

## 6. 測試

**`spec/helpers/`（新增 `shopify_image_variant` 的單元 spec）**
- 標準 Shopify URL 插入尺寸且保留 query string。
- 大寫副檔名同樣處理。
- 無副檔名、非預期格式 → 原樣回傳。
- nil / 空字串 → nil。

**`spec/requests/packages_spec.rb`**
- `store` 參數收斂到該店鋪；無效 id 與他公司 id 都退回「全部」而非 500 或洩漏。
- 店鋪欄的表頭與儲存格都不再出現。
- 有圖的 SKU 渲染 `<img>` 且 src 帶尺寸；無 variant 或無 image_url 的 SKU 渲染佔位方塊。
- 只有一間可見店鋪時不渲染店鋪 pill 那一行。

**`spec/system/packages_spec.rb`**
- 點店鋪 pill 後列表收斂，再點「全部」還原。
- hover 縮圖後大圖出現，且其容器是 body 的子節點而非表格內（這正是繞開 overflow 裁切的關鍵，斷言父節點才能真正釘住它）。

## 7. 風險

- **四處 `current_shopify_store` 的連鎖改動**（第 3 節）是本設計最容易出錯的地方。漏改一處會產生只在特定 pill 組合下出現的錯誤，request spec 需涵蓋「選單一店鋪」與「全部」兩種狀態下的列表內容與時區標示。
- **CDN 尺寸轉換基於 URL 格式假設。** 因此設計為「不符合就原樣回傳」，最壞情況是載入原圖（慢），而不是壞掉的連結（沒圖）。
- **商品未同步時整排佔位方塊**（第 5 節），非缺陷但需知悉。
