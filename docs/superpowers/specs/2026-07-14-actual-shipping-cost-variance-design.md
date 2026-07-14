# 實際運費（per-parcel）與差異比較報表 — 設計文件

**日期：** 2026-07-14
**狀態：** 已核准，待實作
**前置設計：** `2026-05-31-shipping-cost-and-net-margin-design.md`（預估運費、`orders.actual_shipping_cost` 保留欄位）、`2026-06-01-split-parcel-shipping-estimate-design.md`（預估的拆包模擬）

## 1. 背景與目標

系統目前只有**預估**運費：`ShippingCostCalculator` 依運價卡（重量帶 × 分區 × CNY 匯率）算出金額，在訂單同步時凍結寫入 `orders.estimated_shipping_cost`。

`orders.actual_shipping_cost` 欄位在 2026-05-31 的設計中就已預留，讀取路徑（`Order#effective_shipping_cost` → Dashboard 的 `COALESCE`）也早已寫成「有實際值就優先用實際值」。但**寫入路徑完全不存在** —— 沒有 route、沒有 controller action、沒有 strong params、沒有 UI、沒有 importer。既有 spec 甚至斷言它永遠是 `nil`。

本設計補上這條寫入路徑，並在其上建立差異比較報表。

**目標：**

1. 讓貨代帳單（Excel）能匯入系統，成為 per-parcel 的實際運費記錄
2. 讓 AI agent 能透過 API 讀寫實際運費
3. 讓使用者能比較「實際 vs 預估」，並**查出差異的原因**

**非目標：** 自動從承運商 API 抓費用（17Track 不提供費用資料）；跨貨代/多份帳單的合併匯入（見 §10）。

## 2. 領域事實（由 2026 年 6 月帳單實證）

分析 `2026.6月SIMON.xlsx`（482 筆資料行）得到的事實，這些是設計的依據：

- **一個訂單可以有多個包裹。** 434 個不同的「交易编号」對應 482 個包裹；39 個訂單是多包裹。
- **補發件是獨立包裹。** 例如 `PKS#3051` 有兩個包裹，店小秘单号分別是 `XMBDE2012399`（原始）與 `XMBDE2012399R1`（補發，`R1` 後綴）。
- **帳單的「交易编号」直接等於 `orders.name`。** 帳單值為 `PKS#3037` 等，DB 實際值為 `PKS#2232` 等，格式同構，join 不需任何字串處理。
- **費用等式在全部 482 筆上零誤差成立：**
  `加单总运费 = 运费总价 + 挂号费 + 税金 + 偏远费 + 操作费`
  Excel 原始公式為 `W = O*P + R + S + T + V`。因此「加单总运费」是該包裹的最終總價，**已包含 2 元操作费**，直接採用即可，不會漏計也不會重複計。
- **固定費用是多包裹超支的主因。** 操作费固定 2 元（482 筆全部）；挂号费隨渠道/國家在 15–79 元之間變動（18 種值）。一個訂單拆成 3 個包裹，就要付 3 次挂号费 + 3 次操作费。偏远费僅 12 筆非零，税金僅 11 筆非零。
- **Excel 底部有兩個總計行，必須排除。** 第 484 列 `=SUM(W2:W483)` = 58,578.977（本檔 482 筆總額）；第 489 列 `=W484+[1]爱德可6月!...+[2]...+[3]...` = 239,735.764（跨四個外部檔案的大總帳）。**本設計只匯入 SIMON 檔格式，另外三個貨代檔不納入。**
- **一份帳單對應單一店鋪。** 482 筆的「店铺名」全部是 `CSFD-STORE1`。

## 3. 資料模型

### 3.1 新表 `parcels`

```ruby
create_table :parcels, id: :uuid do |t|
  t.references :shopify_store, type: :uuid, null: false, foreign_key: true
  t.references :order,         type: :uuid, null: true,  foreign_key: true

  t.string   :identifier,   null: false   # 店小秘「订单编号」— 唯一鍵
  t.string   :internal_no                 # 内部单号（貨代內部號）
  t.string   :tracking_number             # 货运单号 — 可對接 fulfillments
  t.datetime :shipped_at                  # 发货时间
  t.string   :service_channel             # 物流渠道 — 查因主力欄位
  t.string   :zone                        # 分区
  t.string   :country                     # 国家(中)
  t.integer  :actual_weight_g             # 重量
  t.integer  :billed_weight_g             # 计费重(G)

  t.decimal :cost_cny,             precision: 10, scale: 2   # 加单总运费（帳單原值）
  t.decimal :freight_cny,          precision: 10, scale: 2   # 运费总价
  t.decimal :registration_fee_cny, precision: 10, scale: 2   # 挂号费
  t.decimal :tax_cny,              precision: 10, scale: 2   # 税金
  t.decimal :remote_area_fee_cny,  precision: 10, scale: 2   # 偏远费
  t.decimal :operation_fee_cny,    precision: 10, scale: 2   # 操作费

  t.decimal :fx_rate_snapshot, precision: 10, scale: 4       # 匯入當下 store.cost_fx_rate
  t.decimal :cost_amount,      precision: 10, scale: 2       # cost_cny ÷ fx_rate（店鋪幣別）

  t.timestamps
end

add_index :parcels, [:shopify_store_id, :identifier], unique: true
add_index :parcels, :order_id
add_index :parcels, :tracking_number
```

**唯一鍵決策：** `[shopify_store_id, identifier]`。店小秘的「订单编号」在該店鋪內唯一，且補發件天然帶 `R1` 後綴成為獨立值。這個鍵同時是 Excel 重複匯入與 API `POST` 的 upsert 依據。

**`order_id` 可為 null：** 配不上訂單的包裹照樣存下來（帳單的錢一分不漏），在 Index 頁的「未配對包裹」分頁可手動指派。未配對本身就是一個要查因的訊號。

**`shopify_store_id` 不可為 null：** 匯入時由使用者在頁面上選定。這保證即使 parcel 沒有 order，仍然推導得出匯率，`cost_amount` 一定算得出來，不會產生半殘資料。

### 3.2 幣別與匯率快照

`shopify_stores.cost_fx_rate` 是**每個店鋪各自一個值**（decimal 10,4，owner-only 可改），語意是「1 個店鋪幣別 = 多少 CNY」，換算方向為 `CNY ÷ cost_fx_rate = 店鋪幣別`。

帳單是 CNY，`estimated_shipping_cost` 是店鋪幣別（USD）。兩者要能相減，必須統一幣別。

**Parcel 存三個值：**

- `cost_cny` — 帳單原始金額，一分不動。跟貨代對帳時看到的就是這個數字，永遠可審計。
- `fx_rate_snapshot` — 匯入當下的 `store.cost_fx_rate`。
- `cost_amount` — `(cost_cny / fx_rate_snapshot).round(2)`，店鋪幣別，供 rollup 與比較。

**為什麼要快照匯率：** `estimated_shipping_cost` 在同步時就凍結了（`sync_all_orders_service.rb:150-153` 有 `return if ... present?`，永不覆寫），事後改 `cost_fx_rate` 不會回頭重算歷史訂單。實際值若採即時換算，就會出現「一邊凍結、一邊浮動」的不對稱，兩者相減出來的「差異」將失去意義，且月度報表不可重現。快照匯率讓兩邊語意一致。

**已知限制（不在本次範圍）：** 現有的 `estimated_shipping_cost` 與 `unit_cost_snapshot` **沒有記錄當初使用的匯率**，只存了換算結果。因此若差異來自匯率變動，目前無法從預估側追溯。本設計不回頭補這個欄位（歷史資料也補不回來），但 parcel 側從一開始就記錄，未來若要對稱補齊，資料結構已就緒。

### 3.3 Rollup 到 `orders.actual_shipping_cost`

保留既有的 `orders.actual_shipping_cost` 欄位，作為 `SUM(parcels.cost_amount)` 的 denormalized cache。

**觸發時機：** Parcel 建立、更新、刪除後重算所屬訂單。**`order_id` 變更時，舊訂單與新訂單都必須重算**（例如把未配對的包裹掛上訂單，或改掛到另一張訂單）。

```ruby
# Parcel
after_save    :refresh_order_rollups
after_destroy :refresh_order_rollups

def refresh_order_rollups
  ids = [order_id, order_id_previously_was].compact.uniq
  ids.each { |id| Order.find_by(id: id)&.refresh_actual_shipping_cost! }
end

# Order
def refresh_actual_shipping_cost!
  sum = parcels.sum(:cost_amount)
  update_column(:actual_shipping_cost, parcels.exists? ? sum : nil)
end
```

訂單沒有任何 parcel 時，`actual_shipping_cost` 必須寫回 `nil`（而非 0），否則 `effective_shipping_cost` 會誤把 0 當成「有實際值」而不再 fallback 到預估值。

**這個設計的價值：** `Order#effective_shipping_cost`（`order.rb:40`）、`Order#net_profit_per_order`（`order.rb:44`）、`DashboardMetricsService#aggregate_shipping`（`dashboard_metrics_service.rb:142`）**全部不需修改** —— 它們早就寫成優先採用 `actual_shipping_cost`。實際值一填進去，毛利、淨利、Dashboard 覆蓋率全部自動生效。

## 4. 匯入管線

### 4.1 元件切分

**`ParcelBillParser`** — 純解析，不碰 DB。用 `roo` 讀 xlsx，依中文表頭映射欄位，**以「序号」欄有值作為有效資料行的判準**（序号為 1..482 連續無缺，總計行的序号為空，天然被排除）。回傳 rows 陣列 + 解析錯誤陣列。

**`ParcelUpserter`** — 單筆 upsert，依 `[shopify_store_id, identifier]` 查找既有記錄，有則更新、無則建立；解析「交易编号」→ `orders.name` 掛上 `order_id`（找不到則留 null）；計算 `fx_rate_snapshot` 與 `cost_amount`。

**Excel 匯入與 AI agent API 都呼叫同一個 `ParcelUpserter`。** 兩條寫入路徑共用同一套規則，不會出現「agent 寫的跟 Excel 匯的行為不一致」。

### 4.2 預覽確認流程

匯入是**覆蓋式**且直接改動財務數字（實際運費 → 淨利），必須有預覽關卡。

1. `GET /parcels/import` — 選擇店鋪 + 上傳 xlsx
2. 解析檔案；驗證所選店鋪已設定 `cost_fx_rate`（未設定則**在此擋下**，提示先去店鋪設定填匯率，不讓 `cost_amount` 為 null 的殘廢資料進 DB）
3. 比對既有資料，將解析結果寫入 **`parcel_import_batches` 表**（status `pending`，`rows` 存 jsonb）
4. 預覽頁顯示摘要：「解析到 482 筆 — 475 筆新建、7 筆覆蓋既有資料、3 筆未配對到訂單。總金額 58,578.98 CNY（≈ $8,136.00 USD @ 7.2）」，並列出將被覆蓋與未配對的明細
5. 使用者確認 → 讀回該 batch，在單一 transaction 內寫入 parcels → 觸發 rollup → batch 標記為 `completed`

### 4.2.1 暫存為什麼用資料庫而不是 cache

**Solid Cache 在本專案並未真正安裝。** `solid_cache` gem 在 Gemfile 裡、`database.yml` 也有指向 `db/cache_migrate` 的 cache 資料庫設定 —— 但 `db/cache_migrate` 目錄不存在，schema 中沒有 `solid_cache_entries` 表，`config/cache.yml` 不存在，且 `production.rb:50` 的 `config.cache_store` 是註解掉的。Rails 因此退回 **file store（`tmp/cache`）**。

後果會是致命的：預覽把 482 筆寫進 A 容器的本機磁碟，使用者按確認時請求落到 B 容器就讀不到，顯示「預覽已過期」，整批匯入白做。單一容器也躲不掉 —— 一次部署或 `tmp:clear` 就清空。

更根本的問題是語意：**一個正在進行中的匯入是業務狀態，不是快取。** Cache 的契約就是「隨時可以消失」，拿它承載使用者已經花時間確認過的 482 筆金額資料，本來就是錯的抽象。

因此改用專用表：

```ruby
create_table :parcel_import_batches, id: :uuid do |t|
  t.references :shopify_store, type: :uuid, null: false, foreign_key: true
  t.references :user,          type: :uuid, null: false, foreign_key: true   # 誰匯的
  t.string   :filename                                                        # 匯了哪個檔
  t.jsonb    :rows,      null: false, default: []
  t.integer  :row_count, null: false, default: 0
  t.decimal  :total_cny, precision: 12, scale: 2
  t.string   :status,    null: false, default: "pending"                      # pending / completed
  t.datetime :completed_at
  t.timestamps
end
add_index :parcel_import_batches, [ :shopify_store_id, :status ]
```

**額外收穫：這張表就是匯入稽核紀錄。** 哪天某個月的運費數字看起來不對，可以回頭查「這批是誰、什麼時候、從哪個檔案匯進來的」。設計文件 §10 提到未來要支援多貨代帳單時，本來就需要「這批來自哪個檔案」這個資訊 —— 這張表正好是那個基礎，不是為了繞過 cache 而生的權宜之計。

**過期語意：** 不設 TTL。同一使用者對同一店鋪重新上傳時，先刪掉自己先前未確認的 `pending` batch（避免累積）。確認時找不到對應的 pending batch，才顯示「預覽已過期」。

**ActiveStorage 也不用**（同樣未啟用：`config/storage.yml` 存在，但 schema 中沒有 `active_storage_*` 三張表）。解析後的 rows 直接進 jsonb，原始檔案不留存 —— 檔名記在 `filename` 欄位供追溯即可。

### 4.3 新增依賴

**gem `roo`** — 本專案目前**無法讀取 xlsx**。Gemfile 中的 `caxlsx`（4.1）只能**寫**不能讀；既有的 `RateCardRateImporter` 走的是貼上純文字的路徑（`initialize(version:, text:)`），不是檔案上傳。`roo` 是 Rails 生態讀試算表的標準選擇（MIT）。

## 5. Index 頁（訂單維度差異報表）

Controller: `ParcelsController`，路徑 `/parcels`。

**比較單位是訂單，不是包裹。** 因為預估值本身就是訂單層級算出來的（`ShippingCostCalculator` 拿整張訂單的總重去查運價卡），per-parcel 的預估值根本不存在。唯一能對齊的比較單位就是訂單。

**主列表** — 每列一個訂單：

| 訂單 | 預估 | 實際 | 差異 | 差異% | 包裹數 | 渠道 |
|---|---|---|---|---|---|---|
| PKS#3052 | $18.20 | $40.10 | +$21.90 | +120% | 3 | 美国标准（A带电） |

- 排序：差異金額、差異%（SQL 直接算 `actual_shipping_cost - estimated_shipping_cost`，無需新欄位）
- 篩選：日期區間、店鋪、只看多包裹訂單、只看超支
- 展開一列 → 該訂單的 parcel 明細，含完整費用拆解（看得見挂号费被收了幾次，這是超支的直接證據）
- 行內編輯 parcel（沿用 `ProductVariantsController` 既有的 Turbo Stream inline edit / bulk update pattern）

**「未配對包裹」分頁** — 列出 `order_id IS NULL` 的 parcel，可手動指派訂單（指派後自動觸發 rollup）。

## 6. API（供 AI agent）

### 6.1 認證

現有的 `Api::BaseController` 用 `EmailAccount.agent_api_key` 認證（`api/base_controller.rb:16`）。**這對運費資料是錯誤的權限模型** —— 包裹屬於 `Order → ShopifyStore → Company`，與 EmailAccount 無關；拿客服信箱的鑰匙去改公司財務數字，語意不通，且信箱停用會連帶讓運費 agent 失效。

**新增 `companies.agent_api_key`**（string，unique index，owner-only 產生/重置，比照既有的 `regenerate_agent_api_key`）。

**新增 `Api::CompanyBaseController < ActionController::API`**，獨立認證 company key。**不修改現有的 `Api::BaseController`**，既有 ticket API 零風險。

### 6.2 端點

```
GET   /api/v1/parcels                 列表（篩 order_name / date / unmatched）
GET   /api/v1/parcels/:identifier     單筆
POST  /api/v1/parcels                 建立（upsert：同 identifier 即覆蓋）
PATCH /api/v1/parcels/:identifier     更新
GET   /api/v1/orders/:name/shipping   該訂單的預估/實際/差異 + parcel 明細
```

**`POST` 採 upsert 語意** —— 同一 identifier 重複送出即覆蓋，與 Excel 匯入行為完全一致（兩者共用 `ParcelUpserter`）。這讓 AI agent 可以安全重試，不會產生重複記錄。

資料範圍限於該 company 底下所有店鋪的訂單與包裹。

## 7. Dashboard 物流 Section

從現有的單一「運費」卡片，獨立成一個 Section：

1. **預估運費總額 vs 實際運費總額**（同期間、同幣別）
2. **差異金額與百分比** — 「實際比預估多 $1,240 (+18.3%)」，超支紅色、節省綠色
3. **覆蓋率** — 「482 筆訂單中 434 筆有實際運費 (90%)」。覆蓋率低時差異數字不可盡信，故必須與差異並列
4. **多包裹訂單佔比** — 「39 筆訂單拆成 2 個以上包裹」。這是超支的頭號嫌疑犯，放在 Dashboard 上讓使用者不必點進去就知道超支主因
5. **「查看差異明細」按鈕** — 帶著 Dashboard 當前的日期區間跳到 `/parcels`，預設按差異金額由大到小排序

## 8. 權限

沿用既有模型（`Membership#has_permission?`：owner 全通，member 靠 `permissions` 白名單）。

- **檢視 Index / 差異報表**：新增 `parcels` 至 `Membership::AVAILABLE_PERMISSIONS`，可授權給特定 member（例如負責對帳的同事）
- **Excel 匯入、編輯、刪除 parcel**：**owner-only**。這會直接改動實際運費進而改動淨利，且匯入是覆蓋式的 —— 與 `cost_fx_rate` 同一風險等級，系統既有判斷即為 owner-only
- **Company API key 產生/重置**：owner-only

## 9. 測試策略

依專案規範：RSpec + FactoryBot，無 mock，命中真實 DB，維持 95%+ 覆蓋率。

**Model spec**
- Rollup 正確性：新增/更新/刪除 parcel 後 `orders.actual_shipping_cost` 等於 parcel 總和
- `order_id` 搬移時**舊訂單與新訂單雙邊都重算**
- 訂單最後一個 parcel 被刪除後，`actual_shipping_cost` 回到 `nil`（而非 0）
- `[shopify_store_id, identifier]` 唯一性約束
- `cost_amount` 換算正確、`fx_rate_snapshot` 被記錄

**Service spec**
- `ParcelBillParser`：正確映射中文表頭；**排除底部兩個總計行**；缺欄位/格式錯誤的行回報為錯誤
- `ParcelUpserter`：同 identifier 重複呼叫為冪等覆蓋（不產生重複記錄）；「交易编号」配得上時掛上 order，配不上時留 null
- 店鋪未設 `cost_fx_rate` 時匯入被擋下

**Request spec**
- 權限：member 無 `parcels` 權限時不可檢視；非 owner 不可匯入/編輯/刪除
- API：CRUD 各端點；`POST` 的 upsert 語意；Company key 與 EmailAccount key **不可互相通用**（認證隔離）
- 未帶 key / 錯誤 key 回 401

**System spec**
- 上傳 → 預覽（顯示新建/覆蓋/未配對筆數）→ 確認 → 資料落地
- 未配對包裹手動指派訂單
- Parcel 行內編輯
- Dashboard 物流 Section 顯示差異，點按鈕跳轉至 Index 且帶入日期區間與排序

**測試資料**：以真實帳單的代表性列建 factory，涵蓋單包裹、多包裹（`PKS#3052` 的 3 包）、補發件（`XMBDE2012399R1`）、未配對、含偏远费/税金的邊界情況。

## 10. 已知限制與未來延伸

- **只支援 SIMON 檔格式。** 該月另有三份外部貨代檔（「爱德可6月」等，佔總帳 23.9 萬中的 18.1 萬），本次不匯入。未來若要納入，model 不需改動（唯一鍵仍是店小秘订单编号），但匯入頁需記錄「這批來自哪個檔案/貨代」。
- **店鋪需手動選擇。** 帳單的「店铺名」（`CSFD-STORE1`）與系統的 `shopify_stores` 無既有映射關係。未來多店多帳單時，可在店鋪設定新增「店小秘店鋪代號」做自動映射 —— 屆時 parcel 已有 `shopify_store_id`，資料結構完全相容，不會白做。
- **預估側無匯率快照**（見 §3.2）。
- **17Track 不提供費用資料**，實際運費只能靠帳單匯入或人工填寫，無法自動抓取。`parcels.tracking_number` 保留了與 `fulfillments.tracking_number` 對接的能力，供未來交叉驗證帳單與實際物流狀態。
