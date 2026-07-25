# 折包／合併的列表即時回饋與已折包標記

日期：2026-07-25
分支：`feature/packing-split-ux`
狀態：設計已確認，待實作

## 1. 背景

折包功能（PR #228 修好對話框捲動後）現在操作得起來，但操作完之後的回饋是斷的：

1. **modal 不會關。** `split.turbo_stream.erb` 成功時只把 modal 換成來源包裹的 modal，使用者得自己關掉。
2. **背後的列表完全沒動。** 折出來的新箱子要重新整理頁面才看得到，而整頁重整之後它們會散在依時間排序的列表裡，使用者認不出剛才是哪幾箱。
3. **看不出哪些包裹被折過。** 列表沒有任何標記。同一張訂單的三箱長得跟三張獨立訂單一樣。

合併（merge）有完全相同的三個問題，而且更糟：被併掉的箱子已經 `destroy!`，列表卻還顯示著它們，點下去才發現不見了。

## 2. 目標與非目標

**目標**

- 折包／合併成功後自動關閉 modal。
- 列表就地更新，不整頁刷新，且讓使用者一眼認出剛才受影響的是哪幾列。
- 已折包的包裹在列表上有明確標記，含箱號（第幾箱／共幾箱）。

**非目標**

- 不改折包／合併的業務邏輯（`PackageSplitter` / `PackageMerger` 不動）。
- 不做跨頁的「折包歷史」或稽核紀錄。
- 不處理列表排序：就地替換後，新列停在來源列的位置，不會依當前排序重新歸位。下次載入頁面才會排到正確位置。這是刻意的取捨——重新歸位會讓列跳走，正好破壞「認得出是哪幾箱」這個目的。
- 分頁頁尾的總數在就地更新後會過期，要等下次換頁／重新載入才會更新。就地替換只換了列，沒有重新跑 `@total_count` 的查詢——跟「不重新排序」是同一個刻意取捨:即時更新畫面上的列,但不用整頁重新查詢的成本去換頁尾數字的即時性。
- 合併把畫面上僅存的列都清空時（例如當頁只剩一組要合併的箱子），不會補上「沒有包裹」的空狀態提示——那個提示只在整頁載入時判斷 `@total_count.zero?` 才會畫出來，就地移除列不會觸發。同樣要等下次換頁／重新載入才會出現。

## 3. 列表列的 dom id

`_package_row.html.erb` 的 `<tr>` 目前沒有 id，無法被 Turbo Stream 指名。加上 `id="<%= dom_id(package) %>"`（產生 `package_<uuid>`）。這是本設計所有就地更新的前提。

## 4. 關閉 modal

新增自訂 Turbo Stream action。`app/javascript/turbo_stream_actions.js`：

```js
Turbo.StreamActions.dismiss_modal = function () {
  window.dispatchEvent(new CustomEvent("modal:dismiss"))
}
```

掛載需要三處，缺一不可：`config/importmap.rb` 加 `pin "turbo_stream_actions"`（既有的 `pin_all_from` 只涵蓋 `app/javascript/controllers`，不會自動收錄這個檔案），`application.js` 在 `import "@hotwired/turbo-rails"` **之後**加 `import "turbo_stream_actions"`（ES module 依序求值，turbo-rails 先跑，`window.Turbo` 才存在）。

`index.html.erb` 的 modal 容器 `data-action` 追加 `modal:dismiss@window->modal#close`。

`modal_controller#close` 本來就會把 frame 的 innerHTML 清空，而 `open()` 開頭就守衛 `frame.children.length === 0` 直接 return，所以清空不會反過來把 modal 彈開。不需要改 `modal_controller`。

選這個做法而非「把 frame 更新成空字串」：後者只清內容，modal 容器的 `hidden` class 不會被加回去，畫面上會留一個空白的黑底遮罩。

## 5. 折包後的列表更新

`split.turbo_stream.erb` 成功時送三段 stream：

1. `dismiss_modal`
2. `turbo_stream.replace dom_id(@package)` → 渲染該訂單的全部 N 列（`@package.order_packages`，依 number 排序）
3. 新列帶 `package-row-flash` class

失敗路徑完全不變：仍然只 replace modal，帶著 `@split_errors` 讓對話框重開並顯示錯誤橫幅。

**注意**：來源包裹在折包後仍然存在（它是第一箱／餘量箱），所以是「1 列換成 N 列」，不是「刪掉再新增」。

## 6. 合併後的列表更新

對稱處理，但有一個順序陷阱：`PackageMerger#call` 內部會 `box.reload.destroy!` 掉非存活的箱子（`package_merger.rb:57`），所以**必須在呼叫 merger 之前**先把 `order_packages` 的 id 撈出來，事後才知道要移除哪幾列。

`merge.turbo_stream.erb`：

1. `dismiss_modal`
2. `turbo_stream.replace dom_id(@survivor)` → 存活箱那一列（帶 flash）
3. 對「合併前的 id 扣掉存活箱」的每一個 id 送 `turbo_stream.remove`

## 7. 高亮

新插入／更新的列加 `package-row-flash` class，在 `app/assets/stylesheets/application.css` 定義：背景色淡入後在約 2 秒內淡出的 `@keyframes`。

放 `application.css` 而非 Tailwind 來源檔：Propshaft 直接原樣送出，不依賴任何 build 步驟。該檔案已有同樣理由的先例（`.parcels-edit-col`）。

## 8. 「折 1/3」標記

- **位置**：列表的包裹編號欄，編號旁。
- **內容**：`t("packages.split.badge", position: n, total: m)`，zh-TW 為「折 %{position}/%{total}」。
- **出現條件**：該訂單的包裹數 > 1。
- **範圍**：所有狀態頁。折過的包裹一路到出貨都應該看得出來。

**避免 N+1。** `Package#split?` 是 `order_packages.count > 1`，每列一次 COUNT。新增 `app/services/package_sibling_index.rb`：

```ruby
PackageSiblingIndex.new(packages)  # packages: Array<Package> 或 Relation
#=> #call → { package_id => [position, total] }
```

一次 `Package.where(order_id: <頁面上的 order_ids>).pluck(:order_id, :id, :number)`，在 Ruby 端依 number 排序後編號。只回傳 total > 1 的項目，讓 view 端「有值才畫 badge」的判斷最單純。

跨公司安全：傳入的 packages 已經是 `scoped_packages` 出來的，一張訂單只屬於一間店鋪，所以用 order_id 反查到的兄弟箱必然同店。

`index` 與 split／merge 的 turbo_stream 都用同一個服務——後兩者只針對受影響的那幾個包裹建 map，不必掃整頁。

## 9. 順帶修正

`app/assets/stylesheets/application.css` 開頭那段註解宣稱「CI 在跑 system spec 前不會執行 `bin/rails tailwindcss:build`」。這已經不成立——`.github/workflows/ci.yml:119` 的 system-test job 有這一步。註解會誤導下一個要加樣式的人，順手改正。

## 10. 測試

**`spec/services/package_sibling_index_spec.rb`**
- 單箱訂單不出現在結果裡。
- 三箱訂單得到 1/3、2/3、3/3，依 `number` 排序而非建立順序。
- 多張訂單混在一起時各自獨立編號。
- 只發一次查詢（用 `ActiveRecord::Base.connection` 的 query 計數驗證，避免日後被改回 N+1）。

**`spec/requests/packages_spec.rb`**
- 折過的包裹列表出現 badge；未折的不出現。
- badge 在非 `pending_process` 的狀態頁同樣出現。

**`spec/system/packages_spec.rb`**
- 折包後：modal 關閉、列表就地出現 3 列且標記為 1/3、2/3、3/3。
- 未整頁刷新：操作前在 `window` 上設一個變數，操作後確認它還在（頁面重載會清掉它）。
- 合併後：modal 關閉、N 列收回 1 列，被併掉的包裹編號從列表消失。

## 11. 風險

- **就地替換與排序不一致**（第 2 節已說明）：新列停在來源列的位置。刻意如此。
- **自訂 Turbo Stream action 的載入時機**：見第 4 節的三處掛載。漏掉 importmap 的 pin 會讓這個 action 靜默不存在——Turbo 對未知的 action 不會報錯，只會忽略那段 stream，modal 就默默不關。system spec 實際驗證 modal 有關掉，所以這個失效模式會被測到。
