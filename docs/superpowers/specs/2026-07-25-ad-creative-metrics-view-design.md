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
(以官方 `facebook-python-business-sdk` 的 `adsinsights.py` 欄位清單驗證,查無此欄位;
Meta 亦於 2026-01-26 retire 10 秒觀看指標)。

替換為 **2 秒連續播放率**,使用 `video_continuous_2_sec_watched_actions` —
Meta 現行官方 hook 指標,單次 API 呼叫即取得,與廣告管理員數字一致。

其餘評估過但未採用的方案:
- `video_play_curve_actions`(逐秒留存曲線,可取第 3 秒):最貼近原定義,但回傳的是百分比曲線陣列而非絕對值,資料量大且需二次換算。
- `video_p25_watched_actions`:與 50%/75% 同一套邏輯,但短影片 25% 不到 3 秒、長影片遠超過 3 秒,跨素材比較失真。

### 2.2 完播率分母

Meta API 只回傳次數不回傳比率。分母統一使用 `impressions`(展示次數),對齊廣告管理員的「影片播放進度」算法。

## 3. 為什麼不能用 `video_asset` breakdown

Meta 提供 `breakdowns=video_asset`,表面上直接給素材層級聚合,但**不可用於本功能**:

官方文件明確限制 asset breakdowns(`video_asset` / `image_asset` / `body_asset` 等)
只支援 `impressions`、`clicks`、`spend`、`reach`、`actions`、`action_values` —
**完全不含 `video_p50_watched_actions` 等完播欄位**,且主要設計給 Dynamic Creative 使用。

因此改採自行聚合:拉 ad 層每日指標 → 另外建立 ad → 素材對應 → 在本地 DB group by 聚合。
此路徑額外的好處是聚合規則由我們掌握,並可儲存素材縮圖供視圖預覽。

## 4. 資料模型

延續現有 `ad_accounts → ad_campaigns → ad_campaign_daily_metrics` 的命名慣例,新增三張表。
所有主鍵為 UUID(專案硬性規定)。

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

索引:`unique (ad_unit_id, date)`

### 4.4 設計取捨

**每日資料存在 ad 層而非 creative 層。**
素材數字於查詢時 group by 算出。多出的列數有限(90 天 × 廣告數,量級為數萬列),換到兩個好處:
重新同步可直接覆寫單列,不會因部分失敗導致加總錯誤;未來可下鑽「素材在哪些廣告/廣告組跑」。

**圖片素材一併收錄。**
`asset_type` 區分 video/image。圖片素材的第 2–4 欄為 null,CTR/ROAS/生命週期照常計算。
成本近乎為零,且避免視圖莫名少掉一半素材。

**Advantage+ 多素材廣告標記排除。**
`asset_feed_spec.videos[]` 含多支影片時,花費無法乾淨歸屬單一素材。
此類 ad 標記 `multi_asset = true`、`ad_creative_id` 留 null,預設從視圖排除,避免污染數字。

## 5. 同步層

### 5.1 `MetaAdsService` 新增方法

```
sync_ad_units
  GET /act_X/ads
    fields: id,name,adset_id,campaign_id,effective_status,
            creative{id,video_id,image_hash,thumbnail_url,object_story_spec,asset_feed_spec}
  → upsert ad_units,並建立/連結 ad_creatives

  asset_id 解析順序:
    1. creative.video_id                              → asset_type = video
    2. creative.object_story_spec.video_data.video_id  → asset_type = video
    3. creative.image_hash                             → asset_type = image
    4. asset_feed_spec.videos[] 多於一筆              → multi_asset = true,不歸屬素材

sync_ad_insights(start_date, end_date)
  GET /act_X/insights
    level: ad
    time_increment: 1
    fields: ad_id,spend,impressions,clicks,inline_link_clicks,actions,action_values,
            video_continuous_2_sec_watched_actions,
            video_p25_watched_actions,video_p50_watched_actions,
            video_p75_watched_actions,video_p95_watched_actions,video_p100_watched_actions
  日期切成 30 天一段送出,避免單次回應過大
  → upsert ad_unit_daily_metrics

sync_creative_assets
  僅對 thumbnail_url 為 null 的 video 素材:
  GET /{video_id}?fields=title,length,thumbnails,picture
  → 回填 name / duration_seconds / thumbnail_url
```

`actions` / `action_values` 沿用現有的 `extract_action_count` / `extract_action_value`,
action_type 為 `offsite_conversion.fb_pixel_add_to_cart` / `_initiate_checkout` / `_purchase`。

### 5.2 Jobs

| Job | 觸發 | 範圍 |
|-----|------|------|
| `SyncAdCreativesJob(company_id: nil, days: 7)` | `config/recurring.yml`,每小時 | 滾動同步近 7 天 |
| `BackfillAdCreativesJob(ad_account_id:, days: 90)` | 廣告帳號連接時 + 視圖手動按鈕 | 90 天,分 30 天一段 |

兩者皆先 `refresh_token_if_needed!`,跳過 `token_expired?` 的帳號,
per-account rescue 並寫入 `Rails.logger.error`,比照現有 `SyncAdCampaignsJob`。

### 5.3 滾動同步為何是 7 天

歸因回溯會改寫歷史數字。Meta 已於 2026-01-12 移除 7 天/28 天 view-through 歸因窗,
但 **7 天 click 歸因仍存在**,一筆轉化最晚可能在 7 天後才記回當初點擊的日期。

現有 `SyncAdCampaignsJob` 的 2 天回看不足以收斂 —— 會使 D3/D5 ROAS 長期偏低。
7 天是能收斂的最小值。

### 5.4 Rate limit 處理

90 天 backfill 是唯一有量體風險之處。第一版採**同步呼叫 + 30 天分段 + 指數退避**:
捕捉 `Koala::Facebook::APIError` 中的 rate limit,退避後重試。

**先不實作 async insights job**(`POST /insights` 取 `report_run_id` 再輪詢)。
實作與測試成本顯著較高,而 90 天 / 單帳號的量體多半可承受。
真的撞牆再升級,屆時僅需替換 `sync_ad_insights` 內部實作,上層介面不變。

### 5.5 `first_spend_date` 重算

每次同步後,對有新資料的 creative,取其所有 ad_unit 中最早 `spend > 0` 的日期寫回。
此值只會往前移、不會往後跳。

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

- D3 / D5 ROAS:區分兩種情況 —
  素材自 `first_spend_date` 起尚未滿 3 / 5 天(資料不足)顯示空白;
  已滿天數但視窗內 `SUM(spend)` 為 0(資料齊全但無花費)顯示 0
- 圖片素材:第 2–4 欄顯示 `—`
- 生命週期兩欄:實際涵蓋範圍為近 90 天。若 `first_spend_date` 等於回溯起點,加註截斷提示
- `multi_asset` 廣告:預設排除
- 欄位分組表頭:區隔三種時間基準
- i18n:zh-TW / en,比照現有 `ad_campaigns.*` key 命名

## 7. 測試

對齊 CLAUDE.md 的 95% 覆蓋率門檻。RSpec + FactoryBot,不 mock 資料庫;
外部 API 使用 `instance_double(Koala::Facebook::API)`,比照現有 `spec/services/meta_ads_service_spec.rb`。

**Model spec**
- `batch_aggregated_metrics` 聚合數學(多 ad_unit 加總至同一 creative)
- D1 / D3 / D5 視窗邊界(剛好滿 3 天、未滿 3 天、跨月)
- 除以零回傳 0
- 圖片素材完播率欄位為 nil
- `first_spend_date` 重算邏輯(略過 spend = 0 的日期)

**Service spec**
- `sync_ad_units` 的 asset_id 解析四條分支 + `multi_asset` 判定
- `sync_ad_insights` 建立 / 更新每日指標,30 天分段
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

1. **生命週期 = 近 90 天。** 上線超過 90 天的老素材,第 10–11 欄會被截斷,視圖需標記。
2. **Advantage+ 多素材廣告被排除。** 若帳號大量使用此類廣告,涵蓋率會下降。
3. **素材評級 (S/A/B/C) 不在本次範圍。** 需另訂規則,後續工作。
4. **`publisher_platform` 不拆分。** 第 12 欄為常數 `meta`。同一素材在 FB 與 IG 的完播率差異可觀,
   但拆分會使資料列數倍增,列為後續選項。
5. **Meta 資料保留上限 37 個月**,即使未來提高回溯深度也無法超過。
