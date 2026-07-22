# 訂單打包 Phase 2D — 印面單 (label printing) 設計文件

**日期**：2026-07-22
**分支**：`feature/order-packing-phase2d-label`，**從 `feature/order-packing-phase2c` 疊著切**（依賴 2C 的 `packages.raydo_order_id` 與 `pending_label` 流程；2C 在 PR #223，尚未合併 staging）。
**流程**：SDD（brainstorming → 本設計 → writing-plans → 逐任務執行）。
**外部 API 參考**：`docs/superpowers/references/raydo-huali-api.md`（華磊 URL2 面單接口 `PDF_NEW.aspx`；原文 `raydo-huali-api-raw.txt`）。

---

## 一、目標與範圍

對 `pending_label` 且有 `raydo_order_id` 的包裹，向華磊(Raydo) URL2 抓取 **PDF 面單** 交操作員列印。支援**單筆**與**批量**。

**關鍵語意**：**印面單與發貨是兩個獨立操作**。印面單**無狀態變更、可重印**（華磊列印端點是取 PDF，非狀態動作）。

**非目標（留給後續「已交運(shipped)」階段）**：
- `标记发货`（華磊 `postOrderApi.htm`）+ AASM `ship`（pending_label→shipped）。
- 17Track 軌跡註冊 + Shopify tracking 回寫。
- 華磊 `updateOrderWeightByApi`（列印前更新重量）、`selectLabelType.htm`（動態拉列印類型清單）—— 本階段用渠道配置的固定類型，不動態拉。

---

## 二、關鍵決策（brainstorming 拍板）

| # | 決策 | 選定 |
|---|------|------|
| Q1 | 範圍 | **只印面單**（取 PDF、無狀態變更、可重印）；標記發貨/ship/17Track/Shopify 留 shipped 階段 |
| Q2 | PrintType 來源 | **每渠道配預設**：`LogisticsChannel#label_print_type`（default `lab10_10`），渠道表單可改 |
| Q3 | PDF 交付 | **伺服器 proxy 串流**（HTTParty 取 URL2 PDF → `send_data`），`disposition: inline` |
| Q4 | 觸發 | **單筆 + 批量**；批量僅在選取包裹**同一 `label_print_type`** 時成立（華磊一支 URL 合併成一份 PDF），跨類型 → 拒絕提示（不加 PDF 合併 gem） |
| Q5 | 權限 | **`package_shipping?`**（發貨鏈，該權限目前閒置、為此保留） |

---

## 三、資料模型（migration）

`logistics_channels` 新增：

| 欄位 | 型別 | 用途 |
|------|------|------|
| `label_print_type` | string, default `"lab10_10"`, null: false | 華磊列印端點的 `PrintType`；渠道層級 |

無其他 schema 變更、無新 AASM state。`LogisticsChannel` 加 `validates :label_print_type, presence: true`（已有 default，空值不該出現）。

---

## 四、華磊 adapter：`FulfillmentService::Raydo#label_pdf`

`label_pdf(order_ids, print_type) → String（PDF 原始 bytes）`
- `order_ids`：Array，合併為逗號分隔字串。
- GET `URL2/order/FastRpt/PDF_NEW.aspx?PrintType=<print_type>&order_id=<ids>`，用 **`@account.url2_base`**（非 url1_base）。
- 回應是**二進位 PDF**：直接回 `resp.body`（不走既有的 `parse_response`/GBK JSON 解析）。
- 驗證：`url2_base` 空 → `FulfillmentService::Error`（"Raydo URL2 base is not configured"）；HTTP 非 2xx → `FulfillmentService::Error, "Raydo HTTP <code>"`；回應 content-type 非 PDF 或 body 空/非 `%PDF` 開頭 → `FulfillmentService::Error, "Raydo returned a non-PDF label response"`（華磊出錯常回 HTML 錯誤頁）。
- 錯誤處理沿用既有 `get` 的 rescue（連線/URI 例外只露 exception class；此列印 URL 不帶帳密，但仍維持同紀律）。
- 新增一個 `get_binary(base, path, query)` 私有輔助（或參數化既有 get），因既有 `get` 會把 body 當 JSON 解析、且固定用 url1_base。

---

## 五、編排 service：`PackageLabelPrinter`

`PackageLabelPrinter.new(packages).call → Result`

- `packages`：一或多個 Package（controller 已 scoped 到本公司）。
- 驗證（任一不過 → `Result(success: false, error: <symbol/message>)`，不呼叫華磊）：
  - 非空。
  - 全部 `pending_label?`。
  - 全部 `raydo_order_id` 存在。
  - 全部 `logistics_channel` 存在且 `label_print_type` 一致（跨類型 → error `:mixed_type`）。
  - 該公司 raydo `LogisticsAccount#url2_base` 存在（否則 error `:url2_missing`）。
- 通過：取各 `raydo_order_id`，`FulfillmentService.for(account).label_pdf(order_ids, print_type)`，包 `FulfillmentService::Error` → `Result(success: false, error: e.message)`。
- 成功：`Result(success: true, pdf: <bytes>, filename: <"labels_#{code_or_count}.pdf">)`。
- `Result` struct：`success?`, `pdf`, `filename`, `error`。

> account 來源：每個 package 的 `logistics_channel.logistics_account`。批量時全部屬同公司同 raydo 帳號（一公司一 raydo account），以第一個為準即可；仍逐一驗證 channel 存在。

---

## 六、Controller / routes

全部先 `set_package`（單筆）/ `scoped_packages`（批量）→ 跨公司 404；gate `current_membership&.package_shipping?`；失敗 redirect + alert，**絕不 500**。回傳 PDF 用 `send_data`，錯誤則 redirect（無法對 send_data 直接回錯，改導回清單帶 flash）。

- `GET /packages/:id/label`（member）：
  - gate `package_shipping?`；`set_package`（404）。
  - `PackageLabelPrinter.new([@package]).call`；成功 → `send_data result.pdf, type: "application/pdf", disposition: "inline", filename: result.filename`；失敗 → `redirect_to packages_path(state: "pending_label"), alert: t("packages.label.error", ...)`（單筆的 error 分支：非 pending_label / 無運單號 / url2 未設定 / 華磊錯誤。**`:mixed_type` 不會發生**——單筆只有一個包裹一種類型）。
- `POST /packages/labels`（collection）：
  - gate `package_shipping?`。
  - `ids = params[:package_ids]`；`packages = scoped_packages.where(id: ids, aasm_state: "pending_label")`。
  - `PackageLabelPrinter.new(packages).call`；成功 → `send_data`（合併 PDF）；失敗（含 `:mixed_type` / 空 / `:url2_missing` / 華磊錯誤）→ redirect + 對應 alert。

routes：packages member 加 `get :label`；collection 加 `post :labels`。

---

## 七、UI

- **Modal（`_actions`）**：`pending_label?` + `package_shipping?` → 「印面单」按鈕，`link_to label_package_path(id:), target: "_blank"`（新分頁開 PDF，可直接瀏覽器列印）。非 turbo（PDF 不走 turbo frame）。
- **`pending_label` 清單**：多選（沿用 2C 的 `package_bulk` Stimulus controller，identifier `package-bulk`）+「批量打印面单」按鈕；用 `form_with url: labels_packages_path, method: :post, html: { target: "_blank" }` 包住表格，每列 `package_ids[]` checkbox；提交回合併 PDF（新分頁），清單保留。
- **渠道表單（`logistics_channels/_form.html.erb`）**：加 `label_print_type` 欄位（text，或 select 常用值 lab10_10/A4）。
- i18n 三語系（en/zh-TW繁/zh-CN简，結構一致）：按鈕、批量按鈕、各錯誤（混類型/url2未設定/非pending_label/無運單號/華磊錯誤）。

---

## 八、權限模型

印面單（`label` / `labels`）gate 在 `Membership#package_shipping?`（owner 通過）。渠道表單編輯沿用既有 logistics_channels 權限（不變）。

---

## 九、測試要求（CLAUDE.md 強制）

RSpec + FactoryBot，**不 mock DB、打真 DB、95%+ line coverage**；外部 HTTP 用 **WebMock `stub_request`**。每功能 model/service + request + system。

- **Model**：`LogisticsChannel` `label_print_type` 預設 `lab10_10`、presence 驗證。
- **Service**：
  - `Raydo#label_pdf`：WebMock 回二進位 PDF（body 以 `%PDF` 開頭、content-type application/pdf）→ 回 bytes；url2 空 → error；HTTP 500 → error；回 HTML 非 PDF → error。stub 檢查 URL 用 url2_base + PrintType + 逗號合併 order_id。
  - `PackageLabelPrinter`：成功（單/多、同類型合併）、驗證失敗各分支（非 pending_label、無 raydo_order_id、混類型、url2 未設定、空）、華磊錯誤包成 Result。
- **Request**：
  - `label`：gate 雙向（package_shipping 有/無）、跨公司 404、非 pending_label 拒絕、成功回 `application/pdf` + inline、華磊錯誤 redirect+alert。
  - `labels`（批量）：同類型成功回 PDF、混類型 422/redirect+alert、部分非 pending_label 被 scoped 濾掉、權限雙向。
- **System（真 Chrome）**：pending_label Modal 有「印面单」按鈕（link target=_blank）；清單多選顯示批量按鈕。（PDF 內容不在 system spec 斷言——PDF 下載/新分頁難驗；PDF 正確性由 request spec 的 content-type + service spec 覆蓋。）
- **渠道表單**：request/system 驗證 `label_print_type` 可編輯保存。
- 跨公司隔離、權限雙向、外部 API 成功/失敗 皆需覆蓋。

---

## 十、實作順序（給 writing-plans 的粗綱）

1. Migration：`logistics_channels.label_print_type` + model presence 驗證 + specs。
2. `FulfillmentService::Raydo#label_pdf`（+ binary get 輔助）+ WebMock specs。
3. `PackageLabelPrinter` service + specs。
4. Controller `label` / `labels` + routes + request specs。
5. UI：`_actions` 印面单 鈕、pending_label 清單批量表單 + checkbox、渠道表單 label_print_type 欄位、i18n。
6. System specs。
7. 全套 rspec + rubocop + brakeman 綠燈；PR（2C 合併 staging 後指向 staging；stacked）。

---

## 十一、備註

- 華磊列印端點僅需 `order_id + PrintType`（**不帶帳密**），但仍全程走伺服器 proxy（不把 url2_base / order_id 暴露前端），並 gate 權限 + 跨公司驗證。
- `PrintType` 一鍵值（lab10_10 / A4）由華磊後台按渠道配好模板；本階段不呼叫 `selectLabelType.htm`（YAGNI）。
- 批量「同類型才成立」避免引入 PDF 合併相依；若日後要任意混選合併，再引入 `combine_pdf`（純 Ruby）分組取 PDF 併成一份。
