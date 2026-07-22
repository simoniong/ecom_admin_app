# 訂單打包模塊 — Phase 2B-3 交接文件

> 這份文件是跨機器(Mac → VPS)遷移的接續脈絡,**放在 tracked 的 `docs/superpowers/`**
> 所以會隨 `git pull` 到 VPS。Claude 的自動記憶(`~/.claude/...`)是機器本地的、
> **不會**跟著 repo 走,所以必要脈絡都寫在這裡。
>
> ⚠️ **注意**:`.plan/` 目錄(含 `PRD_order_packing.md`、`milestone_stories.md`)在
> `.gitignore` 第 40 行被忽略,**不會 pull 到 VPS**。若你要在 VPS 上看完整 PRD,
> 需手動把 `.plan/` 從 Mac 複製過去(scp / rsync)。為此,本文件已把 2B-3 需要的
> PRD 段落**直接嵌在下方第二節**,即使沒有 `.plan/` 也能完整接續。

**建立時間**:2026-07-21(Mac 上)
**目前分支**:`feature/order-packing-phase2b3`(從 `origin/staging` 切出,已含 2B-2)
**執行方式**:Subagent-Driven Development(逐任務 implement → 複審 → 記錄;整條 branch opus + Codex 複審;最後 PR 到 staging)

---

## 一、目前進度

| 階段 | 內容 | 狀態 |
|------|------|------|
| Phase 1 / 2A / 2B-1 | 打包基礎、列表、自動建包 + snapshot/override | ✅ 已合併 staging |
| **2B-2** | 詳情 Modal + 待審核/待處理 編輯與狀態操作 | ✅ **已合併 staging(PR #211,merge `cc30e6d`)** |
| **2B-3** | **折包(拆分)+ 合併** | ✅ 已完成(分支 `feature/order-packing-phase2b3`,待 PR 到 staging) |
| 2C | 申請運單號(向物流商 API) | ⬜ 之後 |

> 2B-2 正在 staging 上驗收中(用戶手動測試)。若測出問題,優先修 2B-2,再進 2B-3。

## 二、2B-3 範圍(PRD「待處理」段原文摘錄)

> 以下摘自 `.plan/PRD_order_packing.md`「各狀態的處理操作 → 待處理」:
>
> - 可進行**折包**動作:把原本的一個包裹,折成 2 個或多個。
> - 折完的可以**合併**回去變成一個。
> - 仍可修改訂單地址 / 物流渠道 / 報關信息 / 備註信息。
> - 異常處理:1. 移入擱置 2. 打回待審核。

換句話說,2B-3 = 在 **`pending_process`(待處理)** 狀態下,把一個 Package 拆成多個子包裹、
以及把折出來的子包裹合併回一個。地址/物流/報關/備註 編輯(2B-2 已做)在折/合期間仍可用;
擱置(hold)、打回待審核(back_to_review)也已在 2B-2 做好。

**設計伏筆(2B-1 已鋪好)**:每個 Package 有自己的 per-package snapshot(地址 jsonb + 逐項報關),
就是為了讓折包能乾淨地把資料分到子包裹、合併能收攏回去。折包本質是把 `package_items`
(或某個 item 的部分 quantity)重新分配到新的 `Package` 記錄。

> ⚠️ 折包的核心設計問題(2B-3 brainstorming 要拍板):
> - 資料模型:一個 `order` 對多個 `package`(編號 `number` / `package_code` 如何分配子包裹?)
> - `package_items` 如何拆:整項搬移?還是允許拆單一 item 的 quantity?
> - 已 `override` 的 snapshot(地址/報關)在拆分/合併時如何繼承或分裂?
> - 合併時衝突如何處理(不同子包裹地址/物流不一致)?
> - UI:折包對話框(選 items / 分配數量)、合併操作,大概率在 Modal 內 + turbo_stream 局部替換。
>
> **SDD 規定不可跳過設計**:先 brainstorming → 用戶拍板 → 寫 plan → 逐任務執行。

## 三、⚠️ 關鍵決策(與 PRD 字面不同,務必遵守)

**PRD「待審核」段**寫「如果包裹沒有分配物流渠道、沒有填寫必要的報關信息,**不能**跳到待處理」,
**但用戶在 2B-2 已推翻**這個 gate 位置,實作採用的規則是:

- **審核放行(submit_review)= 無條件**,不設任何 gate。
- **齊全檢查的 gate 移到「待處理 → 申請運單號(apply_tracking)」**,那才是 2C 的按鈕會擋的地方。
- 齊全條件:地址完整(name + country_code + address1 + city)+ 已指派物流渠道 +
  每個「未全退」item 的報關完整(中文名 + 英文名 + 申報金額 + 申報重量)。**全退(fully_refunded)item 排除**。
- 2B-2 已實作 `Package#ready_for_tracking?` / `#tracking_blockers`(只做顯示與提示;真正的申請運單號按鈕留給 2C)。

一句話:**讀 PRD 時,凡遇到「跳待處理要齊全」的字眼,一律以上述決策為準。**

## 四、已建立的架構與慣例(2B-3 必須沿用)

**Package 狀態機(AASM,`app/models/package.rb`)**
`pending_review → pending_process → applying_tracking → pending_label → shipped`,另有
`refunded`(終態)、`held`(暫時態,`held_from` 記來源;unhold 用 `update_column` 在 `after`
清 held_from,因 AASM after 跑在 save 之後 —— 別改成 before,guard 是靠 held_from 路由的)。
**折包/合併是 pending_process 狀態下對 Package 記錄的增刪重組,不是新 AASM state。**

**snapshot + override 慣例**
- 地址:`shipping_address_snapshot`(jsonb)+ `address_overridden`(bool)。
- 逐項報關:`PackageItem` 的 customs 欄位 + `customs_overridden`(bool)。
- `PackageAutoBuilder#smart_update` / `#sync_items`(`app/services/package_auto_builder.rb`)在
  override flag 為 true 時**跳過**用 Shopify/variant 資料覆寫,人工編輯能在下次同步後存活。
  **折包產生的新子包裹如何設定這些 flag、以及一個 order 有多個 package 時 auto-builder 如何
  避免重複建包/覆寫,是 2B-3 要特別想清楚並測試的點。**

**Modal 前端模式(`app/views/packages/`)**
- Turbo Frame `#package-modal`;Stimulus:`modal`(開關/backdrop/Esc)、`tabs`(左側分頁,含
  `tabTargetConnected` 讓被 turbo_stream 替換的分頁按鈕重新套 active 樣式)、`edit_toggle`
  (view↔form 切換)、`row_edit`(逐項報關整列一次 PATCH,422 也重繪)。
- Section partials 各有穩定 `dom_id`(`:address` `:customs` `:logistics` `:note` `:readiness`
  `:actions` `:tab_strip_mobile` `:tab_strip_desktop`;item 用 `dom_id(item)`)。
- 聚合指標(分頁綠勾 `_tab_strip`、齊全面板 `_readiness`)被抽成獨立 dom_id 區塊,每次編輯的
  turbo_stream 一併 replace → 存檔後即時更新。折包/合併的 UI 沿用此 dom_id + Stimulus + 局部
  turbo_stream replace 模式。

**權限模型(`app/models/membership.rb`)**
`package_review?`(submit_review / back_to_review)、`package_process?`(hold/unhold/
back_to_process、改地址/報關/物流/備註)、`package_shipping?`、`any_packing_permission?`
(列表讀取)。owner 一律通過。**折包/合併屬「處理」→ gate 在 `package_process?`。**
每個寫入 action 都先 `set_package`(`scoped_packages.find` → 跨公司 404)再過權限。

**Controller(`app/controllers/packages_controller.rb`)**
`show` / `transition`(whitelist 事件 → 權限 → case/when 派發,無 dynamic send;無效轉換/
權限失敗一律 422 或 redirect,絕不 500)/ `update_address` / `update_item` /
`update_logistics` / `update_note`。折包/合併新增 member routes + actions,照此模式寫。

## 五、測試要求(CLAUDE.md 強制)

- RSpec + FactoryBot,**無 mock**、打真 DB;**95%+ line coverage**(2B-2 後全套 2239 examples / 96.8%)。
- 每個功能要 model + request + system spec;**Turbo 驅動的 UI 一定要配 system spec**(request 看不到 Turbo 契約違反)。system spec 跑真 Chrome。
- 跨公司隔離、權限雙向、override/snapshot 拆分繼承 都要有測試。

## 六、在 VPS 上接續的第一步

1. `git fetch origin && git checkout feature/order-packing-phase2b3`(此分支已含這份文件與全部 2B-2)。
2.(可選但建議)把 Mac 上的 `.plan/` 複製到 VPS(gitignored,不會自動過去),才有完整 PRD/milestone。
3. 開 Claude,說「繼續 order packing 2B-3」,請它先讀本文件 `docs/superpowers/HANDOFF_order_packing_phase2b3.md`。
4. 走 SDD:**先 brainstorming 2B-3 折包/合併設計**(見第二節的核心設計問題)→ 用戶拍板 → 寫 plan → 逐任務執行。
5. 分支慣例:未來再開新階段從 `origin/staging` 切(staging→main 合併後 main 會領先,別從 main 切)。
   **本分支 upstream 目前指向 `origin/staging`,推送務必用明確指令
   `git push -u origin feature/order-packing-phase2b3`,不要裸 `git push`(會推到 staging)。**

## 七、SDD ledger 注意

之前逐任務進度記在 `.superpowers/sdd/progress.md`,那路徑也被 `.gitignore` 忽略、不會跟到 VPS。
2B-2 的完整記錄已濃縮在本文件。2B-3 開始後可在 VPS 重建自己的 ledger。

## 八、2B-3 交付摘要(折包/合併,Task 1-8 完成)

2B-3 在 `pending_process` 狀態下,把「折包(split)」與「合併(merge)」實作為 **同一 order 底下
sibling package 的增刪重組**,沒有新增 AASM state。核心是 `PackageSplitter`(一次性矩陣分配,
店小秘「拆分订单」式:選來源包裹 + 逐 item 分配數量到多個新箱,允許拆單一 item 的部分 quantity)
與 `PackageMerger`(把同一 order 下所有 `pending_process` 的 sibling **塌回號碼最小的存活包裹**,
地址/物流不一致時前端先警告確認再送出)。Shopify auto-builder 的凍結/恢復完全由 **該 order 的
package 數量動態推導**(`order_packages.count > 1` → 凍結,跳過 smart_update 覆寫;塌回 1 個 →
自動恢復同步),不另外存凍結旗標。Controller 新增 `split` / `merge` member routes,權限掛在既有
`package_process?`;`split_allocations` 的 `to_unsafe_h` 經 Brakeman 掃描確認無警告(key 會在
`PackageSplitter` 內對照來源包裹自身 items 驗證,未知 id 一律 422,值強制轉整數,不會未經檢查
流入 query 或 mass-assignment)。UI 沿用 2B-2 的 Modal + Turbo Frame + dom_id 局部替換慣例,新增
兄弟包裹列(siblings strip)、折包矩陣對話框、專屬 Stimulus controller(即時餘量計算與送出前驗證)。

**關鍵決策(brainstorming Q1–Q5,詳見
`docs/superpowers/specs/2026-07-21-order-packing-phase2b3-split-merge-design.md`)**:

- **Q1** 折包後 Shopify 同步 → 凍結,條件由「該 order 包裹數 > 1」動態推導;合併回 1 個自動恢復。
- **Q2** 商品項拆分粒度 → 允許拆單一 item 的部分 quantity(同款商品可分箱)。
- **Q3** 子包裹編號與關聯 → 扁平兄弟,各自從 store 序列取新 `number`,靠 `order_id` 關聯,無
  parent 欄位。
- **Q4** 合併範圍與衝突 → 全單塌回號碼最小的原始包裹;地址/物流不一致先警告確認再塌回。
- **Q5** 折包操作方式 → 一次性矩陣分配(店小秘「拆分订单」式),只作用於單一來源包裹。

**已知且驗收接受的後續事項(non-blocking)**:

- 若某 sibling 包裹處於 `held`(擱置)或 `refunded`(已退款)狀態,會讓整個 order 的 auto-builder
  持續處於凍結,直到該 sibling 被 unhold 並成功合併回去為止;目前行為正確但缺少提示文案,可在
  之後的 UI 打磨中補上說明。
- migration(拿掉 `order_id` 唯一索引)在真實環境已有折包資料後 **不可逆回退**(down migration
  只在資料庫仍是「一 order 一 package」狀態時安全);屬設計上接受的 forward-only 限制。

Task 8 全套驗證(2026-07-21,VPS):RSpec 全套 **2278 examples,0 failures**,line coverage
**96.87%**(≥ 95% 門檻);RuboCop 0 offense;Brakeman 0 warning(含 `split_allocations` 的
`to_unsafe_h` 未被標記)。
