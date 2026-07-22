# 訂單打包 Phase 2B-3 — 折包（拆分）+ 合併 設計文件

**日期**：2026-07-21
**分支**：`feature/order-packing-phase2b3`
**前置**：2B-2 已合併 staging（PR #211）。本文件承接
`docs/superpowers/HANDOFF_order_packing_phase2b3.md`。
**流程**：SDD（brainstorming → 本設計 → writing-plans → 逐任務執行）。

---

## 一、目標與範圍

在 `pending_process`（待處理）狀態下，讓操作者：

1. **折包（split）**：把一個包裹拆成多個子包裹（同一款商品可分箱，允許拆數量）。
2. **合併（merge）**：把同一訂單折出來的多個包裹塌回一個。

折包/合併是對 `Package` 記錄的增刪重組，**不是新的 AASM state**。地址／物流／
報關／備註 編輯（2B-2 已做）、擱置（hold）、打回待審核（back_to_review）在折包
期間仍可用。

**非目標**：不做部分合併（只能全單塌回一個）、不做跨訂單合併、不改齊全檢查
（`ready_for_tracking?` / `tracking_blockers`）的既有語意、不動 2C 的申請運單號。

---

## 二、關鍵決策（brainstorming 拍板）

| # | 決策 | 選定 |
|---|------|------|
| Q1 | 折包後 Shopify 自動同步怎麼辦 | **凍結**，且凍結條件由「該訂單包裹數 > 1」**動態推導**；合併回 1 個後自動恢復同步 |
| Q2 | 商品項拆分粒度 | **允許拆單一 item 的數量**（同款商品可分箱） |
| Q3 | 子包裹編號與關聯 | **扁平兄弟**，各自從 store 序列取新 `number`；靠 `order_id` 關聯；無 parent 欄位 |
| Q4 | 合併範圍與衝突 | **全單塌回號碼最小的原始包裹**；地址／物流不一致時**先警告確認**再塌回 |
| Q5 | 折包操作方式 | **一次性矩陣分配**（店小秘「拆分订单」式），作用於**單一來源包裹** |

**與 PRD 字面不同、務必遵守**（承接 2B-2 決策）：齊全檢查的 gate 在
「待處理 → 申請運單號（apply_tracking，2C）」，折包/合併本身**不設齊全 gate**。

---

## 三、資料模型與 migration

- **移除 `packages` 的 `order_id` 唯一索引**（`index_packages_on_order_id_unique`），
  改成**非唯一索引**（查詢仍需要它）。保留 `shopify_store_id + number` 唯一索引。
- 無新欄位、無新 AASM state、無 `parent_package_id`。
- 折包本質：把來源包裹的 `package_items`（或某項的部分 `quantity`）重新分配到新建的
  `Package` 記錄（新 `number`）。

### 退款不變量（Q2 帶出）

一個 `order_line_item` 折包後會對應到**多個** `package_item`（跨兄弟包裹）。維持：

- 同一 `order_line_item_id` 跨該訂單所有兄弟包裹的 `quantity` 總和 = 原 line item 數量。
- 同一 `order_line_item_id` 跨所有兄弟包裹的 `refunded_quantity` 總和 = 原退款數。

**折包只搬「可出貨數」= `quantity − refunded_quantity`**；已退款單位留在來源項。
因此新子包裹項的 `refunded_quantity` 一律為 `0`，來源項的 `refunded_quantity` 不變。
`PackageItem#fully_refunded?` / `#customs_complete?`、`Package#shippable_items` /
`#customs_complete?` / `#tracking_blockers` **完全沿用，不需修改**。

邊界：若把某項全部可出貨單位都搬走，來源項只剩退款單位 → `fully_refunded?` 為真 →
自動被 `shippable_items` 排除，不影響齊全檢查（來源包裹可能變成「無可出貨項」，允許存在，
之後可由合併收攏）。

---

## 四、Auto-builder 凍結（`PackageAutoBuilder`）

`do_call` 的既有分支改為以「該訂單目前的包裹數」路由：

```
count = @store.packages.where(order_id: @order.id).count
- fully_refunded?（整單全退）：
    count == 1 → refund 那一個（現況）
    count == 0 → 不動
    count > 1  → 跳過（凍結；靠人工，Modal 顯示提示）
- 非全退：
    count == 0 → build_package（現況）
    count == 1 → smart_update（現況，尊重 override flag）
    count > 1  → 跳過（凍結）
```

- 現有 `find_by(order_id:)`（回傳任意一個）在 count>1 時語意不明，故用 `count` 明確路由，
  count>1 一律早退，不呼叫 `smart_update` / `refund`。
- `build_package` 內的 `exists?(order_id:)` 早退保護維持（避免重複建包）。
- 合併回 1 個後 count==1 → 下次 sync 自動恢復 `smart_update`（仍尊重 override）。

**全退凍結取捨（Q1 已接受）**：折包狀態整單全退時 auto-builder 不自動轉子包裹為
`refunded`，需人工處理（例如先合併再讓它退，或逐箱 `refund`）。Modal 顯示提示。

---

## 五、折包（split）

### Service：`PackageSplitter`

- 輸入：來源 `package`、分配矩陣（`{ order_line_item_id => [新包裹的數量, ...] }`，
  對應對話框「包裹2..N」欄；包裹1=來源餘數，由總數扣除得出）。
- 前置：來源必須 `pending_process`；否則拒絕（controller 已 gate，service 亦防禦）。
- 交易：`@store.with_lock`（取號序列）+ 建立 N−1 個新兄弟包裹。每個新包裹：
  - `number` 取自 store 序列（比照 `build_package`：`package_number_seq` 遞增，with_lock 防重號）。
  - `order`、`shopify_store` 同來源。
  - `shipping_address_snapshot` = 複製來源；`address_overridden` = 複製來源。
  - `logistics_channel_id` = 繼承來源。
  - `note` = 空。
  - 對每個分配到 >0 的 line item：建立 `package_item`，複製來源項的 customs 欄位
    + `customs_overridden`、`product_variant_id`、`order_line_item_id`、`sku`、`title`；
    `quantity` = 分配數；`refunded_quantity` = 0。
- 來源包裹：每項 `quantity` 扣掉搬走的總數（餘數）；搬到 0 且無退款則刪除該來源項
  （避免 quantity=0 違反 `greater_than: 0`）。

### 驗證（service + 前端）

- 每列（line item）跨「包裹1..N」的分配總和 = 該項可出貨數（`quantity − refunded_quantity`）。
- 每個目標包裹（含餘數包裹1）至少 1 件可出貨（**不得有空箱**）。
- 至少 2 個非空包裹（**真的有拆**，否則是 no-op）。
- 分配數為非負整數、不超過該項可出貨數。
- 違規 → 422，重繪對話框 + 錯誤（**絕不 500**），比照 `update_item` 的 422 慣例。

### Controller / route

- `post :split`（member）。`set_package` → `package_process?` gate → 非 `pending_process`
  回 422/redirect → 呼叫 `PackageSplitter` → 成功 `turbo_stream` 局部替換（來源 Modal
  更新 + 兄弟包裹列出現）。失敗 422 重繪對話框。

### UI（店小秘「拆分订单」矩陣，作用於單一來源包裹）

- Turbo Frame 對話框；表格：列 = 來源包裹的可出貨商品項，欄 = 「商品信息 / 报关信息 /
  总数 / 包裹1（餘數，自動）/ 包裹2 / 包裹3 …」。
- 「**添加包裹**」新增一欄；每新增欄有 **✕** 移除（包裹1 不可移除）。
- **包裹1 欄為自動餘數** = 总数 − 其他欄總和；其他欄為數字輸入。
- Stimulus controller（新 `split` controller）：即時重算餘數、每欄底部小計
  （商品种类/总数量、重量 by `customs_weight_grams`）、`min/max` 約束、送出前基本驗證。
- 送出走 `turbo_stream` 局部替換，沿用現有 `dom_id` 慣例。

---

## 六、合併（merge）

### Service：`PackageMerger`

- 輸入：訂單（或該訂單任一兄弟包裹）。
- 存活者 = 該訂單 `pending_process` 兄弟中 `number` 最小者（原始包裹）。
- 交易內：
  - 各兄弟的 `package_items` 按 `order_line_item_id` 收攏到存活者：同 line item 的
    `quantity`、`refunded_quantity` 加總（回復退款不變量）；存活者已有該項則加總其上，
    否則搬移過來（保留存活者既有 customs；被吸收者的 customs 丟棄——同 line item 報關本應一致）。
  - 包裹層欄位（地址快照 / `address_overridden` / `logistics_channel_id` / `note`）
    以存活者為準。
  - 銷毀其餘兄弟包裹（其 `number` 留 gap，等同刪除，可接受）。
- 合併後該訂單 count==1 → auto-sync 恢復。

### 衝突警告（Q4）

- 合併前偵測兄弟間 **地址快照或 `logistics_channel_id` 不一致**；若不一致，前端先跳
  確認（Stimulus）「將丟棄其他箱子的地址/物流，保留原始包裹的」，確認才送出。
- 一致則直接合併。

### Controller / route

- `post :merge`（member）。`set_package` → `package_process?` gate → 僅
  `pending_process` → `PackageMerger` → `turbo_stream` 替換為存活者 Modal。失敗
  422/redirect 不 500。

---

## 七、Modal 整合

- 當該訂單包裹數 > 1（折包狀態）：Modal 頂部顯示**兄弟包裹列**（新 partial，穩定 `dom_id`）：
  - 列出同訂單各兄弟 `package_code`，可點擊切換（Turbo Frame 載入該箱 Modal），
    標示目前這箱。
  - 放「**合并**」按鈕（觸發衝突偵測 + 確認 + `post :merge`）。
  - 顯示凍結提示：「此訂單已折包，Shopify 自動同步暫停；整單全退需人工處理」。
- 折包按鈕（開啟拆分對話框）放在現有 `_actions` partial，`pending_process` 才顯示。
- 全部沿用 `dom_id` + Stimulus + 局部 `turbo_stream` replace 慣例（2B-2 已建立）。

---

## 八、權限模型

- 折包／合併屬「處理」→ gate 在 `Membership#package_process?`（owner 一律通過），
  與 hold/unhold/改地址/報關/物流/備註 同一把 gate。
- 每個寫入 action 先 `set_package`（`scoped_packages.find` → 跨公司 404）再過權限。

---

## 九、測試要求（CLAUDE.md 強制）

RSpec + FactoryBot、**無 mock、打真 DB、95%+ line coverage**。每功能 model + request + system。

- **Model / Service**
  - `PackageSplitter`：矩陣分配正確、退款不變量（quantity/refunded 總和）、繼承
    （地址/override/物流/報關/customs_overridden）、來源餘數與空項刪除、驗證失敗
    （空箱、總和不符、無實際拆分、超量、負數）。
  - `PackageMerger`：收攏加總、存活者選定（最小 number）、存活者欄位優先、被吸收者銷毀、
    退款不變量回復。
  - `PackageAutoBuilder`：三分支（count 0/1/>1）× 全退/非全退；折包凍結、合併後恢復同步、
    override 仍被尊重、全退凍結邊界。
- **Request**
  - `split` / `merge`：`package_process?` 雙向（有/無權限）、跨公司 404、非
    `pending_process` 拒絕、驗證失敗 422 不 500、成功 turbo_stream。
- **System（真 Chrome，Turbo 契約）**
  - 折包對話框：添加/移除包裹欄、即時餘數與小計、拆分後列表出現新兄弟列。
  - 兄弟包裹列切換、凍結提示顯示。
  - 合併：一致直接合併、地址/物流不一致跳確認、合併後恢復單一包裹。
- 跨公司隔離、權限雙向、override/snapshot 拆分繼承 皆需覆蓋。

---

## 十、實作順序（給 writing-plans 的粗綱）

1. Migration：移除 `order_id` 唯一索引（改非唯一）。
2. `PackageAutoBuilder` 三分支凍結 + specs。
3. `PackageSplitter` service + specs。
4. `PackageMerger` service（含衝突偵測輔助）+ specs。
5. Controller `split` / `merge` + routes + request specs。
6. UI：拆分對話框（矩陣 + `split` Stimulus）、兄弟包裹列 partial、`_actions` 折包/合併按鈕、
   turbo_stream 範本。
7. System specs。
8. 全套 rspec + rubocop + brakeman 綠燈；PR 到 staging（`git push -u origin feature/order-packing-phase2b3`）。
