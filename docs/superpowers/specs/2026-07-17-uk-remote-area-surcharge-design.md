# 偏遠地區附加費（UK Royal Mail Area 2 / Area 3）— 設計文件

**日期：** 2026-07-17
**狀態：** 已與使用者確認（互動式問答），待寫實作計畫
**前置：** 運費估價系統（`ShippingCostCalculator` / `ShippingRateCardVersion` / `ShippingZonePostalRule` / `PostalNormalizer`）、`parcels.remote_area_fee_cny`（實際端已有）

## 1. 背景與目標

Royal Mail 對特定英國郵編額外加收偏遠配送費：
- **Area 2（高地與離島）**：每票 +¥17
- **Area 3（北愛等）**：每票 +¥10

受影響郵編（外碼開頭，含數字範圍）：
- Area 2：`IV, HS, KA27-28, KW, PA20-49, PA60-78, PA80, PH17-26, PH30-44, PH49-50, ZE, GY, JE, IM, FK20`
- Area 3：`BT, TR21-25, AB35-38, AB53-56, FK18-19, PO30-41`

目前**估價不含偏遠費**，所以送到這些郵編的訂單，實際帳單會多一筆 `remote_area_fee_cny`，卻在預估裡缺席 → 差異被誤歸「物流商可能超收」。本功能讓**估價按收件郵編加上對應偏遠費**，與實際同口徑、可對帳。

## 2. 核心概念

- 偏遠費是**在基礎運費之上額外加的固定費**，與「分區（決定用哪個費率）」正交——因此**獨立建模**，不塞進費率卡或分區。
- **按每包裹**加（與實際 `remote_area_fee_cny` 每票、以及 ¥2 操作費一致）；超重拆包時每個子包裹各加一筆。
- **只影響預估**。實際端維持用帳單匯入的 `remote_area_fee_cny`；本規則是「預測應加多少偏遠費」，兩者的差落在對帳。
- **版本化**：規則按生效日期分版本，語意與 `ShippingRateCardVersion` 完全一致（依訂單 `ordered_at.to_date` 取生效日最晚且未過期的版本）。

## 3. 資料模型

### `ShippingRemoteAreaVersion`（新表）
`company_id · country_code · name · effective_from(date) · effective_to(date, nullable) · timestamps`
- 驗證：`name/country_code/effective_from` 必填；`effective_to >= effective_from`（若有）。
- `has_many :rules, class_name: "ShippingRemoteAreaRule", dependent: :destroy`。
- 查找（完全比照 `ShippingRateCardVersion`）：
  ```ruby
  scope :for_lookup, ->(country:, on_date:) {
    where(country_code: country)
      .where("effective_from <= ?", on_date)
      .where("effective_to IS NULL OR effective_to >= ?", on_date)
      .order(effective_from: :desc)
  }
  def self.lookup(company:, country:, on_date:)
    where(company: company).for_lookup(country:, on_date:).first
  end
  ```

### `ShippingRemoteAreaRule`（新表）
`version_id · postal_start · postal_end · surcharge_cny(decimal 10,2) · area_label(string) · timestamps`
- 驗證：`postal_start/postal_end/surcharge_cny` 必填；`postal_end >= postal_start`；`surcharge_cny >= 0`。
- 查找該版本內命中的規則：
  ```ruby
  def surcharge_for(key)
    rules.where("postal_start <= :k AND postal_end >= :k", k: key)
         .order(postal_start: :desc).first
  end
  ```
  多筆重疊時取**最具體**（`postal_start` 最大者），與 `ShippingZonePostalRule` 一致。回傳規則（含 `surcharge_cny` 與 `area_label`）或 nil。

## 4. GB 郵編正規化（`PostalNormalizer` 擴充）

UK 外碼＝1–2 字母 ＋ 1–2 數字（＋可選尾字母，area 判定用不到）。
- `normalize_gb(raw)`：取外碼（空格前那段），→ `<字母(大寫，1–2)><2 位補零數字>` 的 key。
  - `"IV1 1AA"` → 外碼 `IV1` → `IV01`；`"KA27"` → `KA27`；`"GY1"` → `GY01`；`"PA20 …"` → `PA20`。
  - 純字母島嶼碼（GY/JE/IM 的實際郵編仍是 `GY1` 等）照上式處理。
  - 1 字母 area 的碼（如曼徹斯特 `M1`、伯明罕 `B1`）也能正規化（`M01`/`B01`）；因偏遠清單全是 2 字母 area，這類碼**自然落不進任何偏遠範圍＝正確地不算偏遠**（規則的 start/end 與 key 用同一套正規化，字母前綴主導比較，故無誤命中）。
  - 無法解析（空、格式不符）→ nil。
- `range_for("GB", token)`：把匯入 token 展開成 `[start_key, end_key]`：
  - 純字母 `IV` → `["IV00", "IV99"]`（整個區）
  - 範圍 `KA27-28` → `["KA27", "KA28"]`；`PA20-49` → `["PA20", "PA49"]`
  - 單點 `FK20` → `["FK20", "FK20"]`
  - 格式不符 → nil（匯入時該行報錯、不落庫）
- 把 `"GB"` 加進 `SUPPORTED_COUNTRIES`。**不影響基礎分區**：GB 沒有 `ShippingZonePostalRule` 就仍走不分區基礎費率；正規化只是讓偏遠規則能用郵編匹配。

## 5. 估價整合（`ShippingCostCalculator`）

- `resolve` 解析出 basis 後，依訂單收件郵編（`postal_from_order`，shipping-then-billing）查 `ShippingRemoteAreaVersion.lookup(company, country, ordered_at.to_date)` → 該版本 `surcharge_for(key)` → `remote_surcharge_cny`（命中則為金額，未命中為 0）。把它掛在 `Basis` 上（`remote_surcharge_cny`、`remote_area_label`）。
- **每包裹加一筆**：`cost_cny_for` 在算出基礎（含 ¥2 操作費）後，加 `remote_surcharge_cny × 包裹數`（單一帶＝1；超重拆包＝子包裹數）。與操作費同機制。
  - 具體：`cost_cny_for(scope, weight_kg, remote_surcharge_cny = 0)` 內，單帶回 `parcel_cost + remote_surcharge`；拆包回 `Σparcel_cost + remote_surcharge × parcel_count`。
  - `Basis#estimate_cny_for(weight)` 傳入 `@remote_surcharge_cny`；故 per-parcel 預估（用計費重）與訂單預估（用商品總重）都含偏遠費。
- 金額 BigDecimal。未涵蓋國家 / 未命中郵編 → 附加費 0，行為不變。

## 6. 顯示（`/parcels` 預估依據行）

命中偏遠規則時，「預估依據」多一個 chip：`+ ¥17 偏遠費（Area 2）`（i18n；未命中不顯示）。`= 總額` 已含偏遠費、對得上。

## 7. 設定 UI（新頁，仿費率卡版本頁）

- 新頁 `shipping_remote_area_versions`（nav 收在「物流」下，與費率卡/郵編分區同層）。owner 可編輯、有 `shipping` 權限者可看（比照現有費率頁授權）。
- 功能：列出版本（國家 · 生效區間）、新增版本、刪除版本；版本內新增/刪除規則；**批量貼上**匯入規則。
- **匯入格式（對齊使用者的 Excel 欄序，可直接複製貼上）**：每行 `郵編, area, 價格`，**tab 或逗號**分隔（Excel 複製為 tab 分隔）。例：`AB35	area 3	10`。
  - 郵編用 `PostalNormalizer.range_for("GB", token)` 展開為 `[start,end]`（單碼→點規則 start==end；範圍 token 如 `KA27-28` 亦支援，屬加分）。
  - `area` 存入 `area_label`（原樣，如 `area 3`）；`價格` 存入 `surcharge_cny`。
  - 格式錯 / 無法正規化的行回報、不落庫；合法行落庫。
  - 實測來源清單為 **331 行、單碼一行**（area 2=¥17 / area 3=¥10），此格式可直接貼入。
- i18n en/zh-CN/zh-TW。

## 8. 對帳

預估偏遠費（規則預測）與實際 `remote_area_fee_cny`（帳單匯入）不必逐筆相等；差異落在既有「物流商可能超收」拆解裡，與運費/操作費一致。無需新欄位。

## 9. 測試（RSpec + FactoryBot，無 mock，真實 DB，95%+）

- `PostalNormalizer` GB：`normalize_gb`（各式外碼→key）、`range_for`（純字母/範圍/單點/錯誤）。
- `ShippingRemoteAreaVersion.lookup`：生效日期選版本（早於最早版本→nil；跨版本切換）。
- `ShippingRemoteAreaRule#surcharge_for`：命中/未命中/重疊取最具體。
- `ShippingCostCalculator`：GB 訂單郵編命中 Area 2 → 預估 = 基礎 + ¥2 + ¥17；未命中 → 不加；超重拆包 → 偏遠費 ×包裹數；非 GB / 無版本 → 0。
- `/parcels` 預估依據行命中時顯示偏遠費 chip。
- 設定 UI：建立版本、批量匯入（合法行落庫、錯誤行回報）、刪除。
- Mutation 驗證：偏遠費是否真的加進預估、版本生效日邊界、重疊取最具體。

## 10. 已知限制 / YAGNI

- 偏遠規則只餵**預估**；實際照帳單。
- 目前只需 GB，但模型是 `country_code` 通用，未來其他國家可直接加規則。
- 附加費按**下單日**選版本（與費率卡一致），非發貨日。
- 不做「郵編→area」的反查 UI 提示（下單前檢核），純估價用途。
