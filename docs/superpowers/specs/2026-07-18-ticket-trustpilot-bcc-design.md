# Ticket Draft 可選 BCC Trustpilot 邀請信 — 設計文件

日期:2026-07-18
分支:`feature/ticket-trustpilot-bcc`(基於 `origin/staging`)

## 背景與目標

Trustpilot 提供每個商店一組唯一的邀請信箱(例如
`paintkitstudio.com+a43bb38eeb@invite.trustpilot.com`)。只要把某封寄給客人的
郵件 BCC 到這個信箱,Trustpilot 就會自動向該客人寄出評論邀請以收集 review。

需求:在客服 ticket 處於 **Draft** 狀態時,agent 可以**逐張、手動**選擇是否要在
這封回覆寄出時 BCC 該店的 Trustpilot 信箱。**預設不勾**——只針對 agent 判斷「對方
會給好評」的客人才選。每個店鋪的 Trustpilot 信箱不同。

## 現況(相關程式碼)

- Ticket 狀態機:`app/models/ticket.rb`,`enum status { new_ticket, draft, draft_confirmed, closed }`。
  轉到 `draft_confirmed` 時 `EmailScheduler.schedule!` 排程;退回 `draft` 時 `cancel!`。
- 排程與寄出:`EmailScheduler`(收件人時區 8am–10pm 視窗)→
  `SendScheduledEmailJob#perform` → `GmailService#send_message`(用 Mail gem 組 MIME 再送 Gmail API)。
- 寄出後在 `SendScheduledEmailJob` 建立 `ticket.messages` 記錄並把 ticket 設為 `closed`。
- 關聯:`Ticket → EmailAccount → ShopifyStore`(`ticket.email_account.shopify_store`,可能為 nil)。
- 目前寄信流程**完全沒有** cc/bcc 處理。`messages` 表有 `cc` 欄,但沒有 `bcc`。
- Store 設定 UI 在 `app/views/shopify_stores/show.html.erb`,採「每個單欄位一個小表單」
  模式(如 `cost_fx_rate`、`default_service_type`),`ShopifyStoresController#update` 依
  `params[:shopify_store].key?(...)` 分支,並以 `current_membership&.owner?` 做權限 gate。

**決策**:選擇時機在確認排程(draft → draft_confirmed)當下,但真正寄出在稍後,
因此「是否 BCC」必須持久化在 ticket 上,寄出時才讀取。

## 資料層變更(migrations)

1. `shopify_stores.trustpilot_bcc_email` — `string`, nullable。每店的 Trustpilot 唯一信箱。
2. `tickets.bcc_trustpilot` — `boolean`, `null: false`, `default: false`。這張 ticket 確認時是否選擇 BCC。
3. `messages.bcc` — `string`, nullable。實際寄出時 BCC 的信箱(比照既有 `cc` 欄),作為輕量稽核痕跡。

所有表主鍵為 UUID(專案慣例)。

## Model 變更

- `ShopifyStore`:新增 email 格式驗證(允許空白):
  `validates :trustpilot_bcc_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true`。
  注意 Trustpilot 信箱含 `+` 與子網域,`URI::MailTo::EMAIL_REGEXP` 可接受。

## 每店設定 UI(Shopify Store show 頁)

在 `show.html.erb` 比照 `cost_fx_rate` 的單欄位小表單,新增 `trustpilot_bcc_email` 輸入表單
(text input + 儲存按鈕 + 目前值顯示 + 一句 hint 說明用途)。

`ShopifyStoresController#update` 新增分支:

```ruby
if params[:shopify_store].is_a?(ActionController::Parameters) &&
   params[:shopify_store].key?(:trustpilot_bcc_email)
  return redirect_to(...) unless current_membership&.owner?
  if @shopify_store.update(shopify_store_trustpilot_params)
    redirect ... notice: t("shopify_stores.trustpilot_bcc_updated")
  else
    redirect ... alert: errors
  end
  return
end
```

`shopify_store_trustpilot_params` → `permit(:trustpilot_bcc_email)`。權限比照其他設定用 `owner?`。

## Ticket Draft UI(show 頁確認按鈕區)

現況 draft → draft_confirmed 是 `_status_transition_button` partial(`button_to` 用 `params:`
寫死參數,**夾不進 checkbox**)。因此在 draft 分支改用含 checkbox 的 inline `form_with`:

- checkbox「Send Trustpilot review invite (BCC)」,**預設不勾**。
- **只有當 `@ticket.email_account&.shopify_store&.trustpilot_bcc_email.present?` 時才顯示 checkbox**;
  未設定時只顯示原本的確認按鈕(維持既有行為)。
- 使用 Rails 慣例的 hidden `bcc_trustpilot=0` + checkbox `=1`,確保不勾也送出 false;
  每次確認都明確覆寫該旗標(避免退回重確認時殘留舊值)。
- 保留原本的確認提示(turbo_confirm)。

其餘轉換按鈕(退回 new_ticket、關閉、編輯草稿等)不變。

## Controller(TicketsController)

`handle_status_transition`:當這次轉換目標為 `draft_confirmed` 且 params 帶了
`ticket[bcc_trustpilot]` 時,先 `@ticket.update!(bcc_trustpilot: <boolean>)`,再
`transition_status!("draft_confirmed")`(排程在轉換內觸發,此時旗標已就位)。

允許參數:在對應 permit 加入 `:bcc_trustpilot`(狀態轉換路徑會讀取此值)。

## 寄信層(實際注入 BCC + 記錄)

- `GmailService#send_message` 增加選用參數 `bcc:`;有值時 `mail.bcc = bcc`。
- `SendScheduledEmailJob#perform`:寄出前計算
  ```ruby
  bcc = ticket.bcc_trustpilot? ? ticket.email_account&.shopify_store&.trustpilot_bcc_email.presence : nil
  ```
  傳給 `send_message(bcc: bcc)`;並在建立 `ticket.messages` 記錄時寫入 `bcc: bcc`。
  雙重保險:旗標為真但店家未設信箱 → `bcc` 為 nil,不寄 BCC 也不出錯。

## 稽核痕跡(選項 B)

寄出的 `message` 記錄其 `bcc` 欄存實際 Trustpilot 信箱。Ticket show 頁在顯示該訊息時,
若 `message.bcc.present?` 就顯示一個小標記(如「Trustpilot 邀請已發送」badge),
方便日後查哪些客人發過邀請。

## 測試

- **Model**:`ShopifyStore` — trustpilot email 格式驗證(合法/非法/空白)。
- **Request(shopify_stores)**:owner 可設定/更新 trustpilot email;非 owner 被擋(權限 gate)。
- **Request(tickets)**:確認時勾選 → ticket `bcc_trustpilot` 為 true;不勾 → false;
  退回 draft 再不勾確認 → 重設為 false。
- **Job(SendScheduledEmailJob)**:
  - 旗標真 + 店家有信箱 → `GmailService#send_message` 收到 `bcc`,且 message 記錄 `bcc` 有值。
  - 旗標假 → 無 BCC。
  - 旗標真但店家未設信箱 → 無 BCC、不報錯。
- **System(tickets show)**:checkbox 只在店家已設定 trustpilot email 時出現;
  已發邀請的訊息顯示 badge。

## i18n

en / zh-TW / zh-CN 補上:store 設定欄位標籤與 hint、更新成功訊息、ticket checkbox 標籤、
訊息 badge 文案。

## 範圍外(YAGNI)

- 不做「自動判斷是否好評」——完全由 agent 手動勾選。
- 不做全站/批次套用——逐張選。
- 不整合 Trustpilot API——純靠 BCC 邀請信機制。
