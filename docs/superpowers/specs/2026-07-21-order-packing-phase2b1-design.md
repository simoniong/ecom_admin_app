# Phase 2B-1 設計:包裹快照基礎 + 手動同步 + 智慧再同步 + item 退款標示

日期:2026-07-21
分支:`feature/order-packing-phase2b1`(基於 `origin/staging`,已含 2A)
所屬項目:訂單打包處理模塊(PRD `.plan/PRD_order_packing.md`;2A 設計/計畫在 `docs/superpowers/`)。

## 範圍與切塊(2B 拆三塊)

2B(待審核 + 待處理的操作)因牽涉快照/同步基礎與高風險折包,拆成:
- **2B-1(本文件)**:per-package 快照基礎(地址 + 逐 item 報關)、每店手動「同步訂單」按鈕、智慧再同步(未手動改過就刷新、改過就保留)、item 層退款標示。**唯讀顯示退款警示;不含詳情頁與編輯操作。**
- 2B-2:待審核/待處理的操作(審核放行、分配物流、改地址、改報關、改備註、擱置/打回)+ 詳情頁 + 編輯時設定 override 旗標。
- 2B-3:折包 / 合包(移除 order 1:1 unique、改 auto-builder、number 配號、item 數量拆分)—— 最高風險,獨立。

依賴:2B-1 是基礎;2B-2、2B-3 建於其上。快照刻意設計為 **per-package**,折包(2B-3)後每個子包裹天生各有一份,不需回頭改。

**2B-1 明確不含**:詳情頁、任何編輯操作(改地址/報關/備註、分配物流、審核/擱置/打回按鈕)、折包/合包。這些是 2B-2/2B-3。2B-1 建好 override 旗標欄位 + 智慧再同步邏輯,但旗標此階段永遠 false(尚無編輯動作去設),故再同步一律刷新——符合預期。

## 資料模型變更

### `packages` 新增欄位
- `shipping_address_snapshot`(jsonb, default {})—— 建包時快照 `order.shopify_data["shipping_address"]`(整包存,對應 Shopify 地址結構:name/phone/address1/address2/city/province/zip/country/country_code)。
- `address_overridden`(boolean, not null, default false)—— 分區塊 override 旗標;true 時再同步不覆蓋地址(2B-2 的地址編輯動作會設 true)。

### `package_items` 新增欄位
- 報關快照(建包時從對應 `product_variant` 複製):
  - `customs_name_zh`(string)、`customs_name_en`(string)、`declared_value_usd`(decimal 10,2)、`hs_code`(string)、`import_hs_code`(string)、`customs_weight_grams`(decimal 12,3)
  - (用 `customs_weight_grams` 避免與其他 weight 概念混淆;來源是 variant 的 `weight_grams`。)
- `customs_overridden`(boolean, not null, default false)—— 逐 item override 旗標;true 時再同步不覆蓋該 item 報關(2B-2 的報關編輯會設 true)。
- `refunded_quantity`(integer, not null, default 0)—— 該 item 被 Shopify 退款/取消的數量(部分退款帶數量)。`refunded_quantity >= quantity` 即整項全退。

## 建包時快照(擴充 `PackageAutoBuilder#build_package`)

在 2A 的建包流程(複製 line items → package_items)基礎上,建包當下額外:
1. 把 `order.shopify_data["shipping_address"]`(取不到則 `{}`)存入 `package.shipping_address_snapshot`。
2. 每個 package_item 建立時,從其 `product_variant`(若有)複製報關六欄快照(variant 無報關資料則留 nil);`customs_weight_grams` 取 `variant.weight_grams`。
3. `address_overridden` / `customs_overridden` 建包時為 false;`refunded_quantity` 建包時計算(見下,通常 0)。

## 智慧再同步(擴充 `PackageAutoBuilder`,再同步既有包裹時執行)

2A 的 auto-builder 目前對既有包裹**只處理全額退款**,不更新其他資料。2B-1 擴充:當 order 再次同步且已有對應 package(且非 refunded 終態)時,執行一次「智慧更新」:

### 地址
- `package.address_overridden` 為 false → 用 `order.shopify_data["shipping_address"]` 刷新 `shipping_address_snapshot`。
- 為 true → 保留(不覆蓋)。

### items(1:1 期,折包是 2B-3)
逐一比對 order line items 與 package_items(以 `order_line_item_id` 對應):
- line item **數量變更** → 若對應 package_item 的 `customs_overridden` 為 false**且**未被退款,更新 `quantity`。(報關 override 只鎖報關;數量刷新不受報關 override 影響,但被退款的項不動——見退款規則。)
- order **新增** line item → 新增 package_item(複製報關快照,同建包邏輯)。
- line item **被退款/取消**(見退款偵測)→ **不刪除**,設 `refunded_quantity`。

### 報關
- package_item `customs_overridden` 為 false → 用對應 variant 的最新報關資料刷新六欄快照。
- 為 true → 保留。

> 全額退款(整單 refunded)仍走 2A 既有邏輯:`package.refund!`(終態)。智慧更新只在**非終態**包裹上跑。

## item 層退款偵測

從 `order.shopify_data["refunds"]`(Shopify refunds 陣列)取 `refund_line_items`,每筆有 `line_item_id` + `quantity`。彙總每個 line item 的退款總量,寫入對應 package_item 的 `refunded_quantity`。取消(cancelled)的 line item 亦計入(依 Shopify payload 的取消結構,實作時對齊 order.shopify_data 實際欄位)。

- `refunded_quantity` 累計該 item 的退款數量。
- 再同步時重算(以 Shopify 最新 refunds 為準),不累加錯。

## UI(2B-1 只加:同步按鈕 + 退款警示顯示)

### 手動「同步訂單」按鈕
- 位置:打包各狀態列表頁**右上角**(參考店小秘)。
- 行為:點擊 → 排程**當前選中店鋪**(`current_shopify_store`;未選則提示先選店或對可見店)的訂單同步 job(沿用既有 `orders#sync` 的 job,如 `SyncAllShopifyOrdersJob`,scope 到該店)→ flash「同步已排程」→ 不卡畫面。同步 job 跑完後 auto-builder 的智慧更新即生效。
- 權限:有任一打包權限即可觸發(與列表同 gate)。

### 退款警示(列表 `_package_row`)
- 每個 package_item 顯示:若 `refunded_quantity > 0`,加一個警示 badge「已退款 {refunded_quantity}/{quantity}」;若 `refunded_quantity >= quantity`,強標「勿發」(紅色)。
- 目的:打包的人一眼看到「這個 item 別發」,避免誤發已退款商品。

## 權限
沿用 2A:列表與同步按鈕 = 有任一打包權限(`any_packing_permission?`)。2B-1 不新增權限(細分操作權限在 2B-2)。

## 測試(維持 95%+ 覆蓋率)
- **Model**:packages/package_items 新欄位(預設值、驗證);`refunded_quantity` 邏輯。
- **PackageAutoBuilder(建包快照)**:建包時地址快照、報關快照(有/無 variant 報關)、旗標預設 false、refunded_quantity 初值。
- **PackageAutoBuilder(智慧再同步)**:
  - 地址:未 override → 刷新;override(手動設 true 模擬 2B-2)→ 保留。
  - items:數量變更 → 更新;新增 line item → 新增 package_item;報關 override → 保留、未 override → 刷新。
  - item 退款:refunds 帶部分數量 → refunded_quantity 正確;全退 → refunded_quantity >= quantity;再同步重算不累加錯。
  - 終態(refunded)包裹不被智慧更新。
- **Request**:同步按鈕排程該店 job(當前店 scoping);權限 gate。
- **System**:列表退款警示顯示;同步按鈕觸發 + flash。
- i18n:en / zh-TW / zh-CN 同步按鈕、退款警示、勿發 標籤。

## 待釐清 / 風險
- Shopify `refunds` / `cancelled` 在 `order.shopify_data` 的確切結構(實作時對齊既有 payload;`refund_line_items[].line_item_id/quantity`)。
- 同步 job 是否支援「單店 scope」觸發(檢查既有 `orders#sync` 與 `SyncAllShopifyOrdersJob` 的參數;若只支援全公司,2B-1 需加單店參數或用店級 job)。
- 智慧更新的 items 對應以 `order_line_item_id` 為鍵;2A 建包時 package_item 已存 `order_line_item_id`,可直接對應。
