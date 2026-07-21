# Phase 2B-2 設計:包裹詳情彈窗 + 待審核/待處理編輯操作

日期:2026-07-21
分支:`feature/order-packing-phase2b2`(基於 `origin/staging`,已含 2A + 2B-1)
所屬項目:訂單打包處理模塊(PRD `.plan/PRD_order_packing.md`)。

## 範圍與切塊(2B 拆三塊)

- 2B-1(已上 staging):快照基礎 + 手動同步 + 智慧再同步 + item 退款標示。
- **2B-2(本文件)**:包裹**詳情彈窗**(店小秘式 modal)+ 待審核/待處理的編輯與狀態操作:審核放行、擱置/打回、改地址/報關/備註/分配物流(編輯時設對應 override 旗標)、待處理「齊全檢查」helper + 提示、取消訂單標示。
- 2B-3:折包 / 合包(移除 order 1:1、改 auto-builder、number 配號、item 拆分)—— 最高風險,獨立。

**2B-2 明確不含**:折包(拆分按鈕留 2B-3)、運單申請(申請運單號按鈕 + `apply_tracking` 動作留 2C;2B-2 只提供齊全檢查 helper 供 2C 用)、上一個/下一個包裹導航(留後續)。

## UI:包裹詳情彈窗(參考店小秘)

### 桌面(PC):Turbo Frame modal
- 列表包裹 ID 改為連結 → 點擊在一個 **Turbo Frame modal**(置中大對話框)載入 `package show`。
- 內容結構:
  - **頂部資訊條**:賣家(店鋪)、買家 email、買家姓名、包裹總額、包裹 ID(package_code)、來源(Shopify)。
  - **橫向步驟進度條**:pending_review → pending_process → applying_tracking → pending_label → shipped(當前狀態 highlight);held/refunded 特殊標示。純視覺(狀態機視覺化)。
  - **左側縱向 tab**:收貨地址 / 報關信息 / 物流信息 / 備註,每個「完成」時顯示綠勾(依齊全檢查)。
  - **右側區塊內容**:顯示選中 tab;點「編輯」→ 該區塊變表單(保存 / 返回);保存後 Turbo 局部刷新該區塊。
  - **底部固定資訊**:訂單號 / 報關信息 / 訂單產品 表(唯讀)。
  - **底部操作鈕**(2B-2 範圍):審核放行(待審核時)、異常處理(擱置 / 打回)、備註、關閉。**拆分(2B-3)、申請運單號(2C)不放**。

### 手機:同一 partial,響應式
- **同一個 modal + partial**,以 Tailwind 響應式:小螢幕時 modal **全螢幕**;左側縱向 tab → **頂部橫向可滑動 tab 條**;左右並排區塊 → **垂直堆疊**;底部操作鈕 → **吸底工具列**。不做兩套。

### 實作方式(Hotwire)
- Modal:一個共用 `<turbo-frame id="modal">`(在 admin layout 或 packages index)。列表連結 `data-turbo-frame="modal"` 指向 `package_path(package)`;show 回傳 modal 內容(dialog wrapper)。關閉 = 清空 frame(Stimulus 或空 turbo-frame 回應)。
- 各區塊編輯:區塊內獨立表單 PATCH 到對應 member action,回 turbo_stream 局部替換該區塊(仿 product_customs 的 update.turbo_stream 模式)。
- 狀態按鈕:`button_to` PATCH 到對應 member action(submit_review / hold / back_to_review / back_to_process),仿 tickets 的狀態轉換,呼叫 AASM bang(`package.submit_review!` 等),rescue `AASM::InvalidTransition`。

## 資料:無新欄位(沿用 2A/2B-1)

- 地址:`packages.shipping_address_snapshot`(jsonb)+ 編輯時設 `address_overridden = true`。
- 報關:`package_items` 六欄快照 + 編輯時設 `customs_overridden = true`。
- 物流:`packages.logistics_channel_id`(2A 已加,optional)。**無 override 概念**(純設定,smart_update 不碰它)。
- 備註:`packages.note`(既有欄位,目前未使用)。**無 override**。
- 取消標示:即時讀 `package.order.shopify_data["cancelled_at"]`,無新欄位。

## 權限細分(2B-2 必做)

目前只有 `any_packing_permission?`。新增細分 helper 到 `Membership`:
```ruby
def package_review?  = owner? || permissions.include?("package_review")
def package_process? = owner? || permissions.include?("package_process")
```
(以既有風格寫,非 endless-method 亦可。)
- **審核動作**(submit_review、back_to_review)gate 在 `package_review?`。
- **處理動作**(改地址 / 報關 / 物流 / 備註、hold、back_to_process)gate 在 `package_process?`。
- 詳情頁(show)= 有任一打包權限即可看(沿用 `any_packing_permission?`)。
- 各 member action 在 controller 內檢查對應細分權限,無權則導回 / 403。

## 編輯操作明細

### 收貨地址(`package_process?`)
- 表單欄位(對應 shopify shipping_address key):收件人(name)、電話(phone)、手機、國家(country_code + country)、州省(province)、城市(city)、區縣、地址1(address1)、地址2(address2)、門牌、郵編(zip)、公司、稅號。
- 保存 → 寫入 `shipping_address_snapshot`(jsonb)+ 設 `address_overridden = true`。
- 之後再同步不覆蓋(2B-1 的 smart_update 已尊重 address_overridden)。

### 報關信息(`package_process?`,逐 item)
- 每個 package_item 六欄(customs_name_zh / customs_name_en / declared_value_usd / hs_code / import_hs_code / customs_weight_grams)逐列編輯(仿 product_customs 的 row-edit)。
- 保存該 item → 寫六欄 + 設該 item `customs_overridden = true`。
- 之後再同步不覆蓋該 item 報關(2B-1 已尊重 customs_overridden)。

### 物流信息(`package_process?`)
- 下拉選 `current_company.raydo_logistics_account&.logistics_channels&.order(:name)`(公司範圍),顯示 name(+ product_shortname)。
- 保存 → 設 `package.logistics_channel_id`。

### 備註(`package_process?`)
- textarea → `packages.note`。

## 待處理齊全檢查(helper + 提示,按鈕 2C 接)

`Package#ready_for_tracking?`(+ `Package#tracking_blockers`(回缺什麼的清單,供提示)):
- **地址齊全**:`shipping_address_snapshot` 的 收件人(name)、國家(country_code)、地址1(address1)、城市(city)四項皆 present。
- **物流已分配**:`logistics_channel_id` present。
- **報關齊全**:每個**未全退**(`!fully_refunded?`)的 package_item 的 中文名 / 英文名 / 申報金額 / 申報重量 四項皆 present。
- `ready_for_tracking?` = 三者皆滿足。`tracking_blockers` 回人類可讀的缺項清單(如「未分配物流渠道」「SKU XXX 缺申報金額」「缺收件城市」)。
- 詳情頁在「待處理」狀態顯示齊全狀態(綠勾 / 紅字缺項);2C 的「申請運單號」按鈕以 `ready_for_tracking?` 為 enable 閘門。
- 左側 tab 的綠勾:地址 tab 綠勾 = 地址四項齊;報關 tab 綠勾 = 所有未全退 item 報關齊;物流 tab 綠勾 = 已分配。

## 狀態操作(2B-2 範圍)

- **審核放行**:待審核(pending_review)時,「審核」按鈕 → `package.submit_review!`(→ pending_process)。**無條件**(依使用者確認:審核放行無前置)。gate `package_review?`。
- **打回**:pending_process → pending_review(`back_to_review!`);applying_tracking/pending_label → pending_process(`back_to_process!`,後者主要 2C 用)。gate 對應權限。
- **擱置**:任何非終態(pending_review/process/applying/label)→ held(`hold!`,寫 held_from)。gate `package_process?`。詳情頁 held 狀態顯示「還原」(`unhold!` 回 held_from)。
- 這些沿用 2A 已定義的 aasm events,2B-2 只接 controller action + UI。

## 取消訂單標示

- `Package#order_cancelled?` = `order.shopify_data["cancelled_at"].present? && order.financial_status != "refunded"`(取消但未退款;全額退款已走 refunded 終態)。
- 在**詳情頁 + 列表**顯示「訂單已取消」警示(類似 item 退款的「勿發」紅標),提醒不要繼續打包/發貨。

## 測試(維持 95%+ 覆蓋率)

- **Model(Membership)**:`package_review?` / `package_process?`(owner / 有權 / 無權)。
- **Model(Package)**:`ready_for_tracking?`(三條件組合)、`tracking_blockers`(缺項清單)、`order_cancelled?`(取消未退款 / 已退款不算 / 未取消)。
- **Request(PackagesController)**:show(權限 gate);審核 submit_review(gate package_review,無權擋);hold/unhold/back_to_review(gate);地址更新(寫 snapshot + address_overridden、gate package_process);報關逐 item 更新(寫六欄 + customs_overridden);物流分配(logistics_channel_id、公司範圍、跨公司不可指定他司 channel);備註更新;無效轉換 rescue(AASM::InvalidTransition 不 500)。
- **System(:js)**:列表點包裹開 modal;切 tab;編輯地址保存 → 局部刷新 + tab 綠勾;審核按鈕 → 步驟條前進;齊全提示(缺物流 → 紅字);取消訂單警示;響應式(小螢幕全螢幕 modal — 至少一個 mobile viewport 斷言)。
- i18n:en / zh-TW / zh-CN 所有新標籤(tab 名、欄位、按鈕、齊全提示、取消標示、權限 label 已在 2A)。

## 待釐清 / 風險

- Modal 的 Turbo Frame 與既有 admin layout 的整合(是否已有共用 modal frame;tickets 有 modal 範本可參考)。
- 報關「必填齊全」的檢查是 helper 層(`ready_for_tracking?`),編輯存檔本身**不強制**逐項必填(可存半套草稿),只在推進時檢查——與 Phase 1 product_customs 的「存檔即強制」不同,這裡是「推進時才檢查」。實作時明確此差異。
- 跨公司:物流下拉只列 current_company 的 channel;package 的 store 屬 current_company;controller 需擋「指定他公司 channel」。
