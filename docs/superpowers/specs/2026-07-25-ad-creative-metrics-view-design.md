# 廣告素材指標視圖 (Ad Creative Metrics View) — 設計文件

日期:2026-07-25
分支:`feature/ad-creative-metrics-view`

## 1. 目標

現有 Ads 模組只有兩層資料:帳號層 (`ad_daily_metrics`) 與 Campaign 層 (`ad_campaign_daily_metrics`),
只能看「結果」,無法回答「哪一支素材好、為什麼好」。

本功能新增**素材層級 (creative level) 視圖**,以單一影片/圖片素材為一列,
呈現完播率、CTR、冷啟動表現 (D1/D3/D5) 與生命週期 ROAS,用於素材優劣判讀與迭代決策。

不在本次範圍:素材評級 (S/A/B/C 級) — 該欄位無法由 API 取得,需另訂規則,列為後續工作。

## 2. 欄位定義

視圖共 12 列,由左至右:

| # | 欄位 | 時間基準 | 算法 | 資料來源 |
|---|------|---------|------|---------|
| 1 | 素材 | — | 縮圖 + 名稱 | `ad_creatives.thumbnail_url` / `.name` |
| 2 | 2秒播放率 | 選定區間 | `video_continuous_2_sec_watched / impressions` | Meta Insights |
| 3 | 50%完播率 | 選定區間 | `video_p50_watched / impressions` | Meta Insights |
| 4 | 75%完播率 | 選定區間 | `video_p75_watched / impressions` | Meta Insights |
| 5 | CTR (Link-Click) | 選定區間 | `inline_link_clicks / impressions` | Meta Insights |
| 6 | 第1天花費 | `first_spend_date` | 該日 `spend` | 每日資料 |
| 7 | 第1天轉化數 | `first_spend_date` | 該日 `purchases` | 每日資料 |
| 8 | D3累計ROAS | `first_spend_date` +0..+2 | `SUM(conversion_value) / SUM(spend)` | 每日資料 |
| 9 | D5累計ROAS | `first_spend_date` +0..+4 | `SUM(conversion_value) / SUM(spend)` | 每日資料 |
| 10 | 生命週期總花費 | 全部已同步日期 | `SUM(spend)` | 每日資料 |
| 11 | 生命週期ROAS | 全部已同步日期 | `SUM(conversion_value) / SUM(spend)` | 每日資料 |
| 12 | 投放平台 | — | 常數 `meta` | `ad_account.platform` |

**三種時間基準混在同一張表**(選定區間 / 素材上線錨點 / 全量),
視圖必須用欄位分組表頭在視覺上分隔,避免誤讀。

### 2.1 關於「3 秒完播率」的替換

原始需求的 3 秒完播率無法實作:Meta Marketing API 已移除 `video_3_sec_watched_actions`
(以官方 `facebook-python-business-sdk` 的 `adsinsights.py` 欄位清單驗證,查無此欄位)。

實作前請以當下的 SDK 欄位清單重新驗證一次,不要依賴本文件記載的日期。

替換為 **2 秒連續播放率**,使用 `video_continuous_2_sec_watched_actions` —
Meta 現行官方 hook 指標,單次 API 呼叫即取得,與廣告管理員數字一致。

其餘評估過但未採用的方案:
- `video_play_curve_actions`(逐秒留存曲線,可取第 3 秒):最貼近原定義,但回傳的是百分比曲線陣列而非絕對值,資料量大且需二次換算。
- `video_p25_watched_actions`:與 50%/75% 同一套邏輯,但短影片 25% 不到 3 秒、長影片遠超過 3 秒,跨素材比較失真。

### 2.2 完播率分母

Meta API 只回傳次數不回傳比率。分母統一使用 `impressions`(展示次數),對齊廣告管理員的「影片播放進度」算法。

### 2.3 影片欄位是 list,不是純量

`video_continuous_2_sec_watched_actions`、`video_p25/p50/p75/p95/p100_watched_actions`
在 API schema 中的型別是 **`list<AdsActionStats>`**,不是整數。回傳形如:

```json
"video_p50_watched_actions": [ { "action_type": "video_view", "value": "1234" } ]
```

寫入整數欄位前必須抽值,不可直接 assign。新增 helper:

```ruby
# 加總整個 list 而非只取 action_type == "video_view" 的那筆,
# 避免 Meta 日後新增 action_type 時靜默漏計。
def extract_video_metric(list)
  return 0 if list.blank?
  list.sum { |a| a["value"].to_i }
end
```

同理,`inline_link_clicks` / `impressions` / `spend` 的 schema 型別是 `string`,
需明確 `.to_i` / `.to_d`(現有 `MetaAdsService` 已是此寫法)。

### 2.4 時區

**Meta insights 回傳的 `date_start` 是「廣告帳號時區」的日期,不是 UTC 也不是 app 時區。**

`ad_accounts.timezone` 已存在,由 Meta OAuth 從 `timezone_name` 寫入
(`app/controllers/meta_oauth_controller.rb:77-82`,無效值 fallback `UTC`)。

因此:
- 同步視窗的起訖日期,以 `ActiveSupport::TimeZone[ad_account.timezone].today` 推算,
  **不可**沿用現有 job 的 `Date.current` / `days.ago.to_date`(那是 app 時區)
- `first_spend_date` 與 D1/D3/D5 視窗一律在該廣告帳號時區內做日期運算
- 跨帳號比較時不做時區正規化 —— 各帳號的「第 1 天」本就以自身投放時區為準

現有 `SyncAdCampaignsJob` / `SyncAdMetricsJob` 有同樣的時區問題,但**不在本次修正範圍**,
以免擴大變更面;新程式碼不沿用該寫法即可。

### 2.5 歸因設定

現有 `MetaAdsService` 的 insights 呼叫沒有指定 `action_attribution_windows` /
`use_account_attribution_setting` / `action_report_time`,等於吃 Meta 預設值。

本功能**明確採用 `use_account_attribution_setting: true`**,理由:
數字要能與客戶自己開廣告管理員看到的對得上,固定寫死視窗反而會造成對不起來的客訴。

代價是不同帳號的 ROAS 口徑可能不同,視圖需在說明文字標註「依各廣告帳號的歸因設定」。
`action_report_time` 維持預設(`impression`),使轉化記回點擊/曝光當日 —— 這正是 §5.3
需要 7 天回看的原因。

## 3. 為什麼不能用 `video_asset` breakdown

Meta 提供 `breakdowns=video_asset`,表面上直接給素材層級聚合,但**不可用於本功能**:

官方文件明確限制 asset breakdowns(`video_asset` / `image_asset` / `body_asset` 等)
只支援 `impressions`、`clicks`、`spend`、`reach`、`actions`、`action_values` —
**完全不含 `video_p50_watched_actions` 等完播欄位**,且主要設計給 Dynamic Creative 使用。

因此改採自行聚合:拉 ad 層每日指標 → 另外建立 ad → 素材對應 → 在本地 DB group by 聚合。
此路徑額外的好處是聚合規則由我們掌握,並可儲存素材縮圖供視圖預覽。

## 4. 資料模型

延續現有 `ad_accounts → ad_campaigns → ad_campaign_daily_metrics` 的命名慣例,新增三張表,
並在 `ad_accounts` 上加兩個同步覆蓋範圍欄位。所有主鍵為 UUID(專案硬性規定)。

### 4.0 `ad_accounts` 新增欄位(同步覆蓋範圍)

| 欄位 | 型別 | 說明 |
|------|------|------|
| `creative_synced_from_date` | date | 已同步 ad 層資料的**最早**日期,nullable(未同步過為 null) |
| `creative_synced_through_date` | date | 已同步 ad 層資料的**最晚**日期,nullable |

這兩欄是 §6.3 判斷「資料是否足以計算」的唯一依據。
不能用日曆天數推算 —— backfill 未跑完、同步失敗、帳號晚於功能上線才連接,
都會讓實際覆蓋範圍小於日曆天數,若只看日曆天數就會把不完整的視窗當成有效值。

**不變式:`[from, through]` 區間內必須沒有洞。**
這兩欄代表的是一段**連續**已同步區間,不是「見過的最早/最晚日期」。
若用 min/max 更新,中間某段同步失敗會留下隱形的洞,而區間看起來仍是完整的 ——
D3/D5 會把缺資料的視窗當成有效值,靜默算出偏低的 ROAS。維護規則見 §5.6。

### 4.1 `ad_creatives` — 素材主檔(聚合單位)

| 欄位 | 型別 | 說明 |
|------|------|------|
| `id` | uuid | PK |
| `ad_account_id` | uuid | FK → `ad_accounts` |
| `asset_type` | string | `video` / `image` |
| `asset_id` | string | Meta `video_id` 或 `image_hash` |
| `name` | string | 素材名稱(影片標題,fallback 為首個 ad_name) |
| `thumbnail_url` | string | 預覽縮圖 |
| `duration_seconds` | integer | 影片長度,圖片為 null |
| `first_spend_date` | date | D1/D3/D5 的錨點,每次同步後重算 |

索引:`unique (ad_account_id, asset_type, asset_id)`、`(ad_account_id)`

### 4.2 `ad_units` — 單支 Meta 廣告(對應關係)

| 欄位 | 型別 | 說明 |
|------|------|------|
| `id` | uuid | PK |
| `ad_account_id` | uuid | FK → `ad_accounts` |
| `ad_creative_id` | uuid | FK → `ad_creatives`,nullable(multi_asset 時為 null) |
| `ad_campaign_id` | uuid | FK → `ad_campaigns`,nullable |
| `ad_id` | string | Meta ad id |
| `ad_name` | string | |
| `adset_id` | string | |
| `status` | string | `active` / `paused` / `deleted`,沿用 `map_campaign_status` |
| `multi_asset` | boolean | default false |

索引:`unique (ad_account_id, ad_id)`、`(ad_creative_id)`、`(ad_campaign_id)`

### 4.3 `ad_unit_daily_metrics` — 每日指標

| 欄位 | 型別 | 預設 |
|------|------|------|
| `id` | uuid | PK |
| `ad_unit_id` | uuid | FK → `ad_units` |
| `date` | date | not null |
| `spend` | decimal(12,2) | 0.0 |
| `impressions` | integer | 0 |
| `clicks` | integer | 0 |
| `inline_link_clicks` | integer | 0 |
| `video_continuous_2_sec_watched` | integer | 0 |
| `video_p25_watched` | integer | 0 |
| `video_p50_watched` | integer | 0 |
| `video_p75_watched` | integer | 0 |
| `video_p95_watched` | integer | 0 |
| `video_p100_watched` | integer | 0 |
| `add_to_cart` | integer | 0 |
| `checkout_initiated` | integer | 0 |
| `purchases` | integer | 0 |
| `conversion_value` | decimal(12,2) | 0.0 |

索引:
- `unique (ad_unit_id, date)` — upsert 用
- `(date, ad_unit_id)` — 視圖的日期區間掃描用。主要查詢是「跨大量 ad_unit 篩一段日期」,
  只有前者的話會走不到理想的索引順序

### 4.4 Model 關聯

比照現有 `AdAccount` 的 `has_many :ad_campaigns` / `has_many :ad_daily_metrics`:

```ruby
class AdAccount
  has_many :ad_creatives, dependent: :destroy
  has_many :ad_units, dependent: :destroy
end

class AdCreative
  belongs_to :ad_account
  # nullify 而非 destroy:廣告刪除不該連帶刪掉素材主檔
  has_many :ad_units, dependent: :nullify
end

class AdUnit
  belongs_to :ad_account
  belongs_to :ad_creative, optional: true
  belongs_to :ad_campaign, optional: true
  has_many :ad_unit_daily_metrics, dependent: :destroy
end
```

### 4.5 設計取捨

**每日資料存在 ad 層而非 creative 層。**
素材數字於查詢時 group by 算出。多出的列數有限(90 天 × 廣告數,量級為數萬列),換到兩個好處:
重新同步可直接覆寫單列,不會因部分失敗導致加總錯誤;未來可下鑽「素材在哪些廣告/廣告組跑」。

**圖片素材一併收錄。**
`asset_type` 區分 video/image。圖片素材的第 2–4 欄為 null,CTR/ROAS/生命週期照常計算。
成本近乎為零,且避免視圖莫名少掉一半素材。

**多素材廣告標記排除,判定依據是「相異媒體資產數」而非只看 videos。**
Dynamic / Flexible / Advantage+ creative 可能在 `asset_feed_spec` 放多支影片、多張圖片、
或影片圖片混用,此時花費無法乾淨歸屬單一素材。

判定規則:`asset_feed_spec` 內 `videos` + `images` 的**相異**媒體資產數 > 1
→ `multi_asset = true`、`ad_creative_id` 留 null,預設從視圖排除。

`asset_customization_rules`(版位客製)**不列入判定** —— 它不拆分花費,見 §5.1。

反過來說,`asset_feed_spec` 內**只有一個**媒體資產是常見情況(Advantage+ 也會這樣產),
必須正常歸屬,不能當成多素材排除 —— 詳見 §5.1 的解析順序。

## 5. 同步層

### 5.1 `MetaAdsService` 新增方法

三個方法**都必須透過現有的 `fetch_all_pages`**(`app/services/meta_ads_service.rb:95`)呼叫。
`/act_X/ads` 與 `/act_X/insights` 兩個 edge 都會分頁,直接用 `get_connections` 只會拿到第一頁。
另外明確帶 `limit: 500`,避免預設頁大小造成過多輪次。

```
sync_ad_units
  GET /act_X/ads            (fetch_all_pages, limit: 500)
    fields: id,name,adset_id,campaign_id,effective_status,
            creative{id,video_id,image_hash,thumbnail_url,object_story_spec,
                     asset_feed_spec}
    # asset_customization_rules 不需拉取 —— 不列入 multi_asset 判定(見下)
  → upsert ad_units,並建立/連結 ad_creatives

sync_ad_insights(start_date, end_date)
  GET /act_X/insights       (fetch_all_pages, limit: 500)
    level: ad
    time_increment: 1
    use_account_attribution_setting: true
    time_range: { since:, until: }        # 日期以廣告帳號時區推算,見 §2.4
    fields: ad_id,spend,impressions,clicks,inline_link_clicks,actions,action_values,
            video_continuous_2_sec_watched_actions,
            video_p25_watched_actions,video_p50_watched_actions,
            video_p75_watched_actions,video_p95_watched_actions,video_p100_watched_actions
  日期切成 30 天一段、**依時間順序**送出,避免單次回應過大
  → upsert ad_unit_daily_metrics(影片欄位用 extract_video_metric 抽值,見 §2.3)
  → 依 §5.6 的連續性規則推進 ad_account.creative_synced_* (不可用 min/max)

sync_creative_assets
  僅對 thumbnail_url 為 null 的 video 素材:
  GET /{video_id}?fields=title,length,thumbnails,picture
  → 回填 name / duration_seconds / thumbnail_url
```

**`asset_id` 解析順序**(由上而下,第一個命中者勝):

| # | 條件 | 結果 |
|---|------|------|
| 1 | `asset_feed_spec` 的 `videos` + `images` **相異**媒體資產總數 > 1 | `multi_asset = true`,不歸屬素材 |
| 2 | `creative.video_id` | video / 該 id |
| 3 | `creative.object_story_spec.video_data.video_id` | video / 該 id |
| 4 | `asset_feed_spec.videos` 恰好 1 筆 | video / `videos[0].video_id` |
| 5 | `creative.image_hash` | image / 該 hash |
| 6 | `asset_feed_spec.images` 恰好 1 筆 | image / `images[0].hash` |
| 7 | `creative.object_story_spec.link_data.image_hash` | image / 該 hash |
| 8 | 以上皆不match | `ad_creative_id` 留 null,`multi_asset = false`,記 log 待查 |

多素材判定放在**第 1 條**是刻意的:必須先排除,否則第 2–3 條會先命中 Advantage+ creative
上殘留的單一 `video_id`,把多素材廣告的全部花費錯誤歸給一支影片。

**判定依據只看「相異媒體資產數」,`asset_customization_rules` 不是獨立的觸發條件。**
版位客製規則只是指定同一批資產在不同版位怎麼呈現,它本身不會把花費拆到多個素材上;
單一媒體 + 客製規則仍是一支素材,必須正常歸屬。
若逕自把「有 rules」當成多素材,會與 §4.5「單一媒體資產必須正常歸屬」直接矛盾,
並誤殺一批其實可歸屬的廣告。客製規則所引用的資產本來就會出現在
`asset_feed_spec.videos` / `.images` 內,計數時自然涵蓋。

第 8 條是「未知形態」的收容分支,與第 1 條的「已知多素材」語意不同,兩者要分開統計,
否則解析邏輯的漏洞會被誤當成 Advantage+ 佔比。

**轉化 action_type 使用完整字串**,沿用現有的 `extract_action_count` / `extract_action_value`
(`app/services/meta_ads_service.rb:81`):

- `offsite_conversion.fb_pixel_add_to_cart`
- `offsite_conversion.fb_pixel_initiate_checkout`
- `offsite_conversion.fb_pixel_purchase`

### 5.2 Jobs

| Job | 觸發 | 範圍 |
|-----|------|------|
| `SyncAdCreativesJob(company_id: nil, min_lookback_days: 7)` | `config/recurring.yml`,每小時 | 滾動同步,回看天數見下 |
| `BackfillAdCreativesJob(ad_account_id:, days: 90)` | 廣告帳號連接時 + 視圖手動按鈕 | 90 天,依時間順序分 30 天一段 |

滾動同步的回看天數**不是固定 7 天**,而是逐帳號計算:

```
lookback = max(該帳號歸因設定的最長點擊窗, min_lookback_days)
# 取不到帳號設定時 fallback 為 min_lookback_days (7)
```

因為採 `use_account_attribution_setting`(§2.5),實際歸因窗由各帳號決定。
寫死 7 天會讓設定了更長窗的帳號長期偏低 —— 見 §5.3。

兩者皆先 `refresh_token_if_needed!`,跳過 `token_expired?` 的帳號,
per-account rescue 並寫入 `Rails.logger.error`,比照現有 `SyncAdCampaignsJob`。

### 5.3 滾動同步為何是 7 天

歸因回溯會改寫歷史數字:`action_report_time` 為預設的 `impression` 時,
一筆轉化會被記回當初點擊/曝光的那一天,而點擊歸因窗最長為 7 天 —— 也就是說
「7 天前那一天」的數字,今天仍可能被改寫。

現有 `SyncAdCampaignsJob` 的 2 天回看不足以收斂,會使 D3/D5 ROAS 長期偏低。
7 天是**下限**,不是固定值 —— 實際回看天數依各帳號的歸因設定計算,規則見 §5.2。

### 5.4 Rate limit 處理

90 天 backfill 是唯一有量體風險之處。第一版採**同步呼叫 + 30 天分段 + 指數退避**:
捕捉 `Koala::Facebook::APIError` 中的 rate limit,退避後重試。

**先不實作 async insights job**(`POST /insights` 取 `report_run_id` 再輪詢)。
實作與測試成本顯著較高,而 90 天 / 單帳號的量體多半可承受。
真的撞牆再升級,屆時僅需替換 `sync_ad_insights` 內部實作,上層介面不變。

### 5.5 `first_spend_date` 重算

每次同步後,對有新資料的 creative,取其所有 ad_unit 中最早 `spend > 0` 的日期寫回。
日期本身來自 API 的 `date_start`,已是廣告帳號時區的日期,直接使用不需轉換(§2.4)。

此值只會往前移、不會往後跳 —— 但這正代表它**是下界而非真值**:
backfill 加深時 `first_spend_date` 可能再往前移。
因此凡是以它為錨點的欄位(第 6–11 欄),都必須配合 §6.3 的截斷判斷一起顯示。

由 §5.6 的不變式保證,`first_spend_date` 必然落在
`[creative_synced_from_date, creative_synced_through_date]` 區間內。

### 5.6 同步覆蓋範圍的推進規則

#### 核心不變式

> **所有 `ad_unit_daily_metrics` 的 `date`,必落在
> `[creative_synced_from_date, creative_synced_through_date]` 這段連續區間內。**

這條不變式是 §5.5 與 §6.3 全部計算的前提。一旦允許區間外存在資料列,
生命週期加總(第 10–11 欄)會納入未被覆蓋範圍認可的資料卻仍顯示為「有效」,
而 `first_spend_date` 也可能落到 `_through_date` 之後 —— 靜默算出錯誤數字。

因此:**不可用 min/max 更新覆蓋範圍**,且**不可寫入區間外的資料**。

#### 規則

- 分段一律**依時間順序**由舊至新處理,且 backfill 的終點固定為「今天」
  (帳號時區),使 backfill 完成後覆蓋範圍必然延伸到當日
- **任一段失敗即中止整趟 backfill**,不再送出後續分段。
  已成功的分段保留,`_through_date` 停在最後一段成功的結尾;
  排程重試,下次從 `_through_date + 1` 續跑
- `_from_date` 只在往前擴張且與現有區間**相鄰或重疊**時才前移
- **滾動同步(`SyncAdCreativesJob`)只處理覆蓋範圍已延伸到當日的帳號**
  (`_through_date >= 帳號時區的今天 - 1`)。
  backfill 尚未完成的帳號直接跳過 —— 否則滾動同步會在近幾天寫入資料,
  與尚未推進到那裡的 backfill 區間之間形成洞,破壞不變式。
  這不會漏資料:backfill 本來就會一路跑到今天

不需要額外的分段狀態表 —— 單一連續區間 + 「失敗即中止」已足以維持不變式。

## 6. 視圖層

### 6.1 路由與控制器

```ruby
# config/routes.rb — locale scope 內
resources :ad_creatives, only: [ :index ] do
  collection { post :sync }
end
```

`AdCreativesController < AdminController`,比照 `AdCampaignsController`:
- 公司 / 群組 scope(`selected_view_group` / `visible_ad_accounts`)
- Shopify store 篩選(`current_shopify_store`)
- 廣告帳號篩選(`params[:ad_account_id]`,支援 `all`)
- 日期區間(`from_date` / `to_date`,預設近 7 天,`Date::Error` 時 fallback)
- 排序欄位白名單 `SORTABLE_COLUMNS`

注意:本專案路由含 `(:locale)` scope,path helper 需使用具名參數而非 positional record。

### 6.2 指標計算

集中於 `AdCreative.batch_aggregated_metrics(creative_ids, date_range)`,
回傳 `CreativeMetrics` Struct,寫法比照現有 `AdCampaign::CampaignMetrics`:

- 單次 SQL `group by` 取回全部分子分母,不產生 N+1
- 所有比率方法除以零一律回傳 0
- 區間指標(第 2–5 欄)與錨點指標(第 6–9 欄)、全量指標(第 10–11 欄)分別查詢後合併

### 6.3 顯示規則

**錨點欄位(第 6–11 欄)共用一個狀態判定**,依據是 §4.0 的實際同步覆蓋範圍,
**不是日曆天數**。集中在 `AdCreative#anchor_state(window_days)`,
由第 6–11 欄各自帶入視窗長度呼叫。

令 `acct = creative.ad_account`、`fsd = creative.first_spend_date`、`n` 為視窗長度
(第 6/7 欄 n = 1;D3 n = 3;D5 n = 5;生命週期 n = nil 表示不檢查長度)。

**依序評估,第一個命中者勝** —— 順序不可調換,條件之間本來就會重疊:

| # | 狀態 | 條件 | 顯示 |
|---|------|------|------|
| 1 | 無花費 | `fsd` 為 null | `—` |
| 2 | 未同步 | `acct.creative_synced_from_date` 或 `_through_date` 為 null | 空白 + 未同步標記 |
| 3 | 起點被截斷 | `fsd <= acct.creative_synced_from_date` | 空白 + 截斷標記 |
| 4 | 資料不足 | `n` 不為 nil 且 `fsd + (n-1) > acct.creative_synced_through_date` | 空白 |
| 5 | 有效 | 其餘 | 數值(視窗內 `SUM(spend)` 為 0 時顯示 0) |

順序理由:
- 1 先於 2 —— 素材根本沒花費過,與帳號有沒有同步無關
- 3 先於 4 —— 錨點本身不可信時,數字是**錯的**而不只是**不完整的**,
  兩者同時成立時必須報較嚴重的那個
- 第 6/7 欄(第 1 天花費 / 轉化數)帶 `n = 1`,走同一條路徑不另立邏輯。
  在 §5.6 的不變式下 `fsd <= _through_date` 恆成立,故狀態 4 對 n = 1 實際不會命中 ——
  但**仍必須實作該檢查**,不可因「理論上不會發生」而略過:
  它是不變式被破壞時唯一的防線

**生命週期兩欄(n = nil)的加總範圍,以覆蓋範圍為界**,
即 `date BETWEEN creative_synced_from_date AND creative_synced_through_date`。
在 §5.6 的不變式下這與「全部已同步日期」等價,但查詢必須明確帶上這個界 ——
不變式一旦被破壞(bug、手動補資料、未來新增的寫入路徑),
沒帶界的加總會靜默納入區間外資料並顯示為有效,帶了界則最多少算,不會謊報。

**狀態 3「起點被截斷」的意義:** `first_spend_date` 只是「已同步範圍內最早有花費的日期」,
是下界不是真值(§5.5)。若它落在同步起點上,這支素材的真實首次花費可能更早,
錨點不可信 —— 第 6–11 欄全部必須標記,不能只標生命週期兩欄。

其餘顯示規則:
- 圖片素材:第 2–4 欄顯示 `—`
- `multi_asset` 廣告:預設排除
- 欄位分組表頭:區隔三種時間基準
- i18n:zh-TW / en,比照現有 `ad_campaigns.*` key 命名

### 6.4 OAuth scope

**不需要變更。** 現有 Meta OAuth 已請求 `ads_management,ads_read`
(`app/controllers/meta_oauth_controller.rb:19`),涵蓋本功能所有唯讀呼叫
(insights / ads / adcreatives / video 節點)。

## 7. 測試

對齊 CLAUDE.md 的 95% 覆蓋率門檻。RSpec + FactoryBot,不 mock 資料庫;
外部 API 使用 `instance_double(Koala::Facebook::API)`,比照現有 `spec/services/meta_ads_service_spec.rb`。

**Model spec**
- `batch_aggregated_metrics` 聚合數學(多 ad_unit 加總至同一 creative)
- `anchor_state` 五態逐一覆蓋,含**條件重疊時的優先序**:
  `fsd <= synced_from` 且 `fsd + n-1 > synced_through` 同時成立時,必須回「起點被截斷」而非「資料不足」
- `fsd` 為 null、coverage 為 null 各自的狀態
- 生命週期加總帶覆蓋範圍界:人工插入一筆區間外的 `ad_unit_daily_metrics`
  (模擬不變式被破壞),生命週期數字**不得**納入它
- 覆蓋範圍邊界:`creative_synced_through_date` 剛好等於 / 差一天於視窗結尾
- backfill 只完成一半時,不得把不完整視窗當有效值
- 除以零回傳 0;視窗內 `SUM(spend)` 為 0 時回 0 而非空白
- 圖片素材完播率欄位為 nil
- `first_spend_date` 重算邏輯(略過 spend = 0 的日期)
- 日期運算在廣告帳號時區進行:同一組資料在 `Asia/Taipei` 與 `America/Los_Angeles`
  帳號下,`first_spend_date` 與 D3 視窗需符合各自時區的預期

**Service spec**
- `sync_ad_units` 的 asset_id 解析**全部 8 條分支**,
  `multi_asset` 的唯一觸發條件是「相異媒體資產數 > 1」
- 特別測「`asset_feed_spec` 只有單一影片/單一圖片」必須正常歸屬,不可誤判為多素材
- 特別測「單一媒體 + `asset_customization_rules`」必須正常歸屬,**不可**判為多素材
- 特別測「多素材 creative 上仍殘留 `video_id`」必須走多素材分支,不可歸給該影片
- 第 8 條未知形態:留 null 且不標記 multi_asset
- 影片欄位 `list<AdsActionStats>` 的抽值(含空 list、多筆 entry 需加總)
- `sync_ad_insights` 帶上 `use_account_attribution_setting`
- 分頁:`fetch_all_pages` 有跟到第二頁(餵兩頁 payload)
- `sync_ad_insights` 建立 / 更新每日指標,30 天分段
- **覆蓋範圍連續性(§5.6)**:第 2 段失敗時整趟中止,第 3 段**不得被送出**,
  `_through_date` 停在第 1 段結尾(這是 min/max 寫法會漏掉的情境)
- **不變式**:任何情況下 `ad_unit_daily_metrics` 都不得存在覆蓋範圍外的 `date`
- 滾動同步跳過 `_through_date` 落後於當日的帳號
- 回看天數依帳號歸因設定計算,取不到時 fallback 7 天
- `sync_creative_assets` 只打未有縮圖的素材
- rate limit 退避重試

**Job spec**
- `SyncAdCreativesJob` 跳過 token 過期帳號、per-account rescue 不中斷其他帳號
- `BackfillAdCreativesJob` 分段呼叫

**Request spec**
- index 的篩選 / 排序 / 日期區間
- 跨公司資料隔離
- `sync` 正確入列 job
- 注意:短字串的 `not_to include` 斷言易與隨機 CSRF token 碰撞,fixture 值需具辨識度

**System spec**
- 表格渲染、欄位排序、日期區間切換、素材縮圖顯示

## 8. 已知限制

1. **生命週期 = 已同步範圍(目標 90 天)。** 首次花費早於同步起點的素材,
   第 6–11 欄全部會被標記為截斷(§6.3 狀態 3)。`first_spend_date` 是
   「已同步範圍內最早有花費的日期」,不保證等於真實上線日。
2. **多素材廣告被排除。** 若帳號大量使用 Dynamic / Flexible / Advantage+ creative,涵蓋率會下降。
   實作後應統計排除比例(以及 §5.1 第 8 條的未知形態比例),比例過高則需重新評估歸屬策略。
3. **ROAS 口徑隨帳號而異。** 採 `use_account_attribution_setting`,跨帳號的 ROAS 不嚴格可比。
4. **素材評級 (S/A/B/C) 不在本次範圍。** 需另訂規則,後續工作。
5. **`publisher_platform` 不拆分。** 第 12 欄為常數 `meta`。同一素材在 FB 與 IG 的完播率差異可觀,
   但拆分會使資料列數倍增,列為後續選項。
6. **Meta 資料保留上限 37 個月**,即使未來提高回溯深度也無法超過。
7. **現有 `SyncAdCampaignsJob` / `SyncAdMetricsJob` 的時區問題未修**(§2.4)。
   新舊兩套的日期口徑會有最多一天的差異,帳號層 / campaign 層與素材層的數字對不起來時,
   這是第一個要查的原因。列為後續工作。
