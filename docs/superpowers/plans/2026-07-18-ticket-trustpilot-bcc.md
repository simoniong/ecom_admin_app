# Ticket Trustpilot BCC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a support agent, per ticket at draft-confirmation time, opt to BCC the store's Trustpilot review-invite address on the outgoing reply.

**Architecture:** A per-store address (`shopify_stores.trustpilot_bcc_email`) is configured on the store settings page. A per-ticket boolean (`tickets.bcc_trustpilot`) captures the agent's opt-in when confirming a draft. At send time, `SendScheduledEmailJob` reads the flag + the store address and passes `bcc:` to `GmailService#send_message`, which adds it to the MIME message; the actual BCC address is recorded on the sent `messages.bcc` row and surfaced as a badge in the ticket UI.

**Tech Stack:** Rails 8.1, PostgreSQL (UUID PKs), Hotwire/Turbo, Tailwind, RSpec + FactoryBot, Mail gem, Gmail API.

## Global Constraints

- All table IDs use UUIDs (project convention).
- RSpec + FactoryBot, no fixtures; 95%+ line coverage required.
- The external Gmail boundary (`GmailService`) is the one place mocking is allowed in specs — follow the existing `spec/jobs/send_scheduled_email_job_spec.rb` pattern (`instance_double(GmailService)`). Everything else hits the real DB.
- Turbo-driven UI must ship a system spec in the same commit (request specs can't see Turbo contract violations).
- Store-settings mutations are gated by `current_membership&.owner?`, mirroring the existing `cost_fx_rate` / `default_service_type` forms.
- i18n keys must be added to all three locales: `config/locales/en.yml`, `config/locales/zh-TW.yml`, `config/locales/zh-CN.yml`.
- Never commit to `main`/`staging`; work on `feature/ticket-trustpilot-bcc` (already checked out from `origin/staging`).

## File Structure

- `db/migrate/*_add_trustpilot_bcc_email_to_shopify_stores.rb` — new column (Task 1)
- `db/migrate/*_add_bcc_trustpilot_to_tickets.rb` — new column (Task 2)
- `db/migrate/*_add_bcc_to_messages.rb` — new column (Task 3)
- `app/models/shopify_store.rb` — email-format validation (Task 1)
- `app/controllers/shopify_stores_controller.rb` — update branch + permit (Task 1)
- `app/views/shopify_stores/show.html.erb` — settings form (Task 1)
- `app/views/tickets/show.html.erb` — draft confirm form + checkbox (Task 2); message badge (Task 3)
- `app/controllers/tickets_controller.rb` — persist flag in status transition (Task 2)
- `app/jobs/send_scheduled_email_job.rb` — compute + pass bcc, record on message (Task 3)
- `app/services/gmail_service.rb` — `bcc:` param (Task 3)
- `spec/factories/messages.rb` — no change needed; `bcc` is nil by default (Task 3)
- Specs alongside each task.

---

### Task 1: Per-store Trustpilot BCC address (config + settings UI)

**Files:**
- Create: `db/migrate/20260718120001_add_trustpilot_bcc_email_to_shopify_stores.rb`
- Modify: `app/models/shopify_store.rb` (validations block, after line 22)
- Modify: `app/controllers/shopify_stores_controller.rb` (add update branch after line 45; add permit method after line 87)
- Modify: `app/views/shopify_stores/show.html.erb` (add a settings card after the `default_service_type` card, line 121)
- Modify: `config/locales/en.yml`, `config/locales/zh-TW.yml`, `config/locales/zh-CN.yml`
- Test: `spec/models/shopify_store_spec.rb`, `spec/requests/shopify_stores_spec.rb`

**Interfaces:**
- Produces: `ShopifyStore#trustpilot_bcc_email` (String, nilable). Consumed by Tasks 2 (UI visibility) and 3 (send-time BCC).

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260718120001_add_trustpilot_bcc_email_to_shopify_stores.rb
class AddTrustpilotBccEmailToShopifyStores < ActiveRecord::Migration[8.1]
  def change
    # Each store has its own unique Trustpilot invite address; BCC'ing it on a
    # reply triggers Trustpilot to email that customer a review invitation.
    add_column :shopify_stores, :trustpilot_bcc_email, :string
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: migration runs; `schema.rb` gains `t.string "trustpilot_bcc_email"` under `shopify_stores`.

- [ ] **Step 3: Write the failing model spec**

Add to `spec/models/shopify_store_spec.rb` (inside the top-level `RSpec.describe ShopifyStore`):

```ruby
describe "trustpilot_bcc_email" do
  it "is valid when blank" do
    store = build(:shopify_store, trustpilot_bcc_email: nil)
    expect(store).to be_valid
  end

  it "accepts a Trustpilot plus-addressed email" do
    store = build(:shopify_store, trustpilot_bcc_email: "paintkitstudio.com+a43bb38eeb@invite.trustpilot.com")
    expect(store).to be_valid
  end

  it "rejects a malformed address" do
    store = build(:shopify_store, trustpilot_bcc_email: "not-an-email")
    expect(store).not_to be_valid
    expect(store.errors[:trustpilot_bcc_email]).to be_present
  end
end
```

- [ ] **Step 4: Run it to verify it fails**

Run: `bundle exec rspec spec/models/shopify_store_spec.rb -e "trustpilot_bcc_email"`
Expected: FAIL — "not-an-email" is currently accepted (no validation yet).

- [ ] **Step 5: Add the validation**

In `app/models/shopify_store.rb`, immediately after the `default_service_type` validation (line 22):

```ruby
  validates :trustpilot_bcc_email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
```

- [ ] **Step 6: Run it to verify it passes**

Run: `bundle exec rspec spec/models/shopify_store_spec.rb -e "trustpilot_bcc_email"`
Expected: PASS (3 examples).

- [ ] **Step 7: Add i18n keys (all three locales)**

`config/locales/en.yml` under `shopify_stores:` (sibling of `default_service_type`):

```yaml
    trustpilot_bcc: "Trustpilot review invitations"
    trustpilot_bcc_hint: "BCC this store's unique Trustpilot address on selected ticket replies to auto-request a review. Leave blank to disable."
    trustpilot_bcc_placeholder: "yourdomain.com+xxxx@invite.trustpilot.com"
    save_trustpilot_bcc: "Save"
    trustpilot_bcc_updated: "Trustpilot invitation address updated."
    trustpilot_bcc_owner_only: "Only an owner can change this."
```

`config/locales/zh-TW.yml`:

```yaml
    trustpilot_bcc: "Trustpilot 評論邀請"
    trustpilot_bcc_hint: "在選定的 ticket 回覆 BCC 這個店鋪專屬的 Trustpilot 信箱,即可自動向客人邀請評論。留空則停用。"
    trustpilot_bcc_placeholder: "yourdomain.com+xxxx@invite.trustpilot.com"
    save_trustpilot_bcc: "儲存"
    trustpilot_bcc_updated: "Trustpilot 邀請信箱已更新。"
    trustpilot_bcc_owner_only: "只有擁有者可以變更。"
```

`config/locales/zh-CN.yml`:

```yaml
    trustpilot_bcc: "Trustpilot 评论邀请"
    trustpilot_bcc_hint: "在选定的工单回复 BCC 这个店铺专属的 Trustpilot 信箱,即可自动向客人邀请评论。留空则停用。"
    trustpilot_bcc_placeholder: "yourdomain.com+xxxx@invite.trustpilot.com"
    save_trustpilot_bcc: "保存"
    trustpilot_bcc_updated: "Trustpilot 邀请信箱已更新。"
    trustpilot_bcc_owner_only: "只有拥有者可以变更。"
```

- [ ] **Step 8: Add the controller update branch + permit**

In `app/controllers/shopify_stores_controller.rb`, insert after line 45 (after the `default_service_type` branch, before the `email_account_ids` block):

```ruby
    if params[:shopify_store].is_a?(ActionController::Parameters) && params[:shopify_store].key?(:trustpilot_bcc_email)
      return redirect_to(shopify_store_path(@shopify_store), alert: t("companies.no_permission")) unless current_membership&.owner?

      if @shopify_store.update(shopify_store_trustpilot_params)
        redirect_to shopify_store_path(@shopify_store), notice: t("shopify_stores.trustpilot_bcc_updated")
      else
        redirect_to shopify_store_path(@shopify_store), alert: @shopify_store.errors.full_messages.join(", ")
      end
      return
    end
```

And add this private method after `shopify_store_service_params` (after line 87):

```ruby
  def shopify_store_trustpilot_params
    params.require(:shopify_store).permit(:trustpilot_bcc_email)
  end
```

- [ ] **Step 9: Add the settings card to the store show page**

In `app/views/shopify_stores/show.html.erb`, insert after line 121 (after the `default_service_type` card's closing `</div>`):

```erb
  <div class="mt-6 bg-white shadow-sm rounded-lg border border-gray-200 p-6">
    <h2 class="text-lg font-medium text-gray-900"><%= t("shopify_stores.trustpilot_bcc") %></h2>
    <p class="mt-1 text-sm text-gray-500"><%= t("shopify_stores.trustpilot_bcc_hint") %></p>
    <% if current_membership&.owner? %>
      <%= form_with url: shopify_store_path(@shopify_store), method: :patch, local: true,
                    class: "mt-3 flex items-center gap-2" do %>
        <input type="email"
               name="shopify_store[trustpilot_bcc_email]"
               id="shopify_store_trustpilot_bcc_email"
               value="<%= @shopify_store.trustpilot_bcc_email %>"
               placeholder="<%= t("shopify_stores.trustpilot_bcc_placeholder") %>"
               aria-label="<%= t("shopify_stores.trustpilot_bcc") %>"
               class="w-96 max-w-full border border-gray-300 rounded px-2 py-1 text-sm">
        <button type="submit"
                class="px-3 py-1 text-sm bg-blue-600 text-white rounded hover:bg-blue-700">
          <%= t("shopify_stores.save_trustpilot_bcc") %>
        </button>
      <% end %>
    <% else %>
      <p class="mt-3 text-sm text-gray-700">
        <strong><%= @shopify_store.trustpilot_bcc_email.presence || "—" %></strong>
        <span class="text-xs text-gray-500 ml-2"><%= t("shopify_stores.trustpilot_bcc_owner_only") %></span>
      </p>
    <% end %>
  </div>
```

- [ ] **Step 10: Write the failing request spec**

Add to `spec/requests/shopify_stores_spec.rb` (a new `describe`):

```ruby
describe "PATCH /shopify_stores/:id trustpilot_bcc_email" do
  let(:user)  { create(:user) }
  let(:store) { create(:shopify_store, user: user, company: user.companies.first) }

  it "lets an owner set the Trustpilot BCC address" do
    sign_in user
    patch shopify_store_path(store), params: { shopify_store: { trustpilot_bcc_email: "shop.com+abc@invite.trustpilot.com" } }
    expect(store.reload.trustpilot_bcc_email).to eq("shop.com+abc@invite.trustpilot.com")
  end

  it "rejects a malformed address" do
    sign_in user
    patch shopify_store_path(store), params: { shopify_store: { trustpilot_bcc_email: "nope" } }
    expect(store.reload.trustpilot_bcc_email).to be_nil
    follow_redirect!
    expect(response.body).to include(CGI.escapeHTML("Trustpilot"))
  end

  it "forbids a non-owner member from changing it" do
    member = create(:user)
    create(:membership, user: member, company: user.companies.first, role: :member, permissions: [ "shopify_stores" ])
    sign_in member
    patch switch_company_path(id: user.companies.first.id)
    patch shopify_store_path(store), params: { shopify_store: { trustpilot_bcc_email: "shop.com+abc@invite.trustpilot.com" } }
    expect(store.reload.trustpilot_bcc_email).to be_nil
  end
end
```

- [ ] **Step 11: Run the request spec**

Run: `bundle exec rspec spec/requests/shopify_stores_spec.rb -e "trustpilot_bcc_email"`
Expected: PASS (3 examples).

- [ ] **Step 12: Lint + commit**

```bash
bin/rubocop app/models/shopify_store.rb app/controllers/shopify_stores_controller.rb
git add db/migrate app/models/shopify_store.rb app/controllers/shopify_stores_controller.rb app/views/shopify_stores/show.html.erb config/locales db/schema.rb spec/models/shopify_store_spec.rb spec/requests/shopify_stores_spec.rb
git commit -m "feat(stores): configure per-store Trustpilot BCC invite address"
```

---

### Task 2: Per-ticket opt-in at draft confirmation

**Files:**
- Create: `db/migrate/20260718120002_add_bcc_trustpilot_to_tickets.rb`
- Modify: `app/controllers/tickets_controller.rb` (`handle_status_transition`, lines 222-243)
- Modify: `app/views/tickets/show.html.erb` (draft → draft_confirmed block, lines 117-124)
- Modify: `config/locales/en.yml`, `config/locales/zh-TW.yml`, `config/locales/zh-CN.yml`
- Test: `spec/requests/tickets_spec.rb`, `spec/system/tickets_spec.rb`

**Interfaces:**
- Consumes: `ShopifyStore#trustpilot_bcc_email` (Task 1) for checkbox visibility.
- Produces: `Ticket#bcc_trustpilot` (Boolean, default false). Consumed by Task 3 at send time.

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260718120002_add_bcc_trustpilot_to_tickets.rb
class AddBccTrustpilotToTickets < ActiveRecord::Migration[8.1]
  def change
    # Captured when the agent confirms the draft; read later at send time.
    add_column :tickets, :bcc_trustpilot, :boolean, null: false, default: false
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: `schema.rb` gains `t.boolean "bcc_trustpilot", default: false, null: false` under `tickets`.

- [ ] **Step 3: Persist the flag in the controller**

In `app/controllers/tickets_controller.rb`, change the first line of `handle_status_transition` (line 223) from:

```ruby
    @ticket.transition_status!(params.dig(:ticket, :status))
```

to:

```ruby
    if params.dig(:ticket, :status) == "draft_confirmed" && params[:ticket].key?(:bcc_trustpilot)
      @ticket.update!(bcc_trustpilot: ActiveModel::Type::Boolean.new.cast(params.dig(:ticket, :bcc_trustpilot)))
    end
    @ticket.transition_status!(params.dig(:ticket, :status))
```

- [ ] **Step 4: Add i18n keys (all three locales)**

`config/locales/en.yml` under `tickets.show:`:

```yaml
      trustpilot_bcc_label: "Send Trustpilot review invite (BCC)"
```

`config/locales/zh-TW.yml` under `tickets.show:`:

```yaml
      trustpilot_bcc_label: "發送 Trustpilot 評論邀請(BCC)"
```

`config/locales/zh-CN.yml` under `tickets.show:`:

```yaml
      trustpilot_bcc_label: "发送 Trustpilot 评论邀请(BCC)"
```

- [ ] **Step 5: Replace the confirm button with a checkbox form**

In `app/views/tickets/show.html.erb`, replace the draft → draft_confirmed block (lines 117-124):

```erb
          <%# draft → draft_confirmed %>
          <% if @ticket.draft? %>
            <%= render "tickets/status_transition_button",
                ticket: @ticket, target_status: "draft_confirmed",
                label: t("tickets.show.confirm_schedule"),
                color: "green", icon: "check",
                confirm: t("tickets.show.confirm_schedule_confirm") %>
          <% end %>
```

with:

```erb
          <%# draft → draft_confirmed (with optional Trustpilot BCC opt-in) %>
          <% if @ticket.draft? %>
            <% trustpilot_addr = @ticket.email_account&.shopify_store&.trustpilot_bcc_email %>
            <% if trustpilot_addr.present? %>
              <%= form_with url: ticket_path(id: @ticket.id), method: :patch, class: "inline-flex items-center gap-2" do %>
                <input type="hidden" name="ticket[status]" value="draft_confirmed" />
                <input type="hidden" name="ticket[bcc_trustpilot]" value="0" />
                <label class="inline-flex items-center gap-1.5 text-sm text-gray-700">
                  <input type="checkbox" name="ticket[bcc_trustpilot]" value="1"
                         class="rounded border-gray-300 text-green-600 focus:ring-green-500" />
                  <%= t("tickets.show.trustpilot_bcc_label") %>
                </label>
                <button type="submit"
                        class="inline-flex items-center gap-1.5 px-4 py-2 bg-green-600 hover:bg-green-700 text-white text-sm font-medium rounded-md focus:outline-none focus:ring-2 focus:ring-offset-2 focus:ring-green-500 cursor-pointer"
                        data-controller="confirm-button"
                        data-action="click->confirm-button#fire"
                        data-confirm-button-confirm-text-value="<%= t("tickets.show.confirm_schedule_confirm") %>">
                  <svg class="w-4 h-4" aria-hidden="true" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M9 12.75 11.25 15 15 9.75M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0Z" />
                  </svg>
                  <%= t("tickets.show.confirm_schedule") %>
                </button>
              <% end %>
            <% else %>
              <%= render "tickets/status_transition_button",
                  ticket: @ticket, target_status: "draft_confirmed",
                  label: t("tickets.show.confirm_schedule"),
                  color: "green", icon: "check",
                  confirm: t("tickets.show.confirm_schedule_confirm") %>
            <% end %>
          <% end %>
```

Note: the `confirm-button` Stimulus controller and this two-step confirm pattern are exactly the ones used by the existing "close ticket" inline form (lines 144-155), so no new JS is needed.

- [ ] **Step 6: Write the failing request spec**

Add to `spec/requests/tickets_spec.rb`:

```ruby
describe "PATCH /tickets/:id draft_confirmed with Trustpilot BCC" do
  let(:user)  { create(:user) }
  let(:store) { create(:shopify_store, user: user, company: user.companies.first, trustpilot_bcc_email: "shop.com+abc@invite.trustpilot.com") }
  let(:email_account) { create(:email_account, user: user, company: user.companies.first, shopify_store: store) }
  let(:ticket) { create(:ticket, :draft, email_account: email_account) }

  before { sign_in user }

  it "stores bcc_trustpilot=true when the box is checked" do
    patch ticket_path(id: ticket.id), params: { ticket: { status: "draft_confirmed", bcc_trustpilot: "1" } }
    expect(ticket.reload.bcc_trustpilot).to be(true)
    expect(ticket).to be_draft_confirmed
  end

  it "stores bcc_trustpilot=false when the box is unchecked (hidden 0 only)" do
    patch ticket_path(id: ticket.id), params: { ticket: { status: "draft_confirmed", bcc_trustpilot: "0" } }
    expect(ticket.reload.bcc_trustpilot).to be(false)
  end

  it "resets a previously-true flag when re-confirmed unchecked" do
    ticket.update!(bcc_trustpilot: true)
    ticket.update!(status: :draft) # walk back to draft
    patch ticket_path(id: ticket.id), params: { ticket: { status: "draft_confirmed", bcc_trustpilot: "0" } }
    expect(ticket.reload.bcc_trustpilot).to be(false)
  end
end
```

- [ ] **Step 7: Run the request spec**

Run: `bundle exec rspec spec/requests/tickets_spec.rb -e "Trustpilot BCC"`
Expected: PASS (3 examples).

- [ ] **Step 8: Write the system spec (checkbox visibility — Turbo-driven form)**

Add to `spec/system/tickets_spec.rb`:

```ruby
describe "Trustpilot BCC opt-in", :js do
  let(:user) { create(:user) }

  it "shows the checkbox only when the store has a Trustpilot address" do
    store = create(:shopify_store, user: user, company: user.companies.first, trustpilot_bcc_email: "shop.com+abc@invite.trustpilot.com")
    account = create(:email_account, user: user, company: user.companies.first, shopify_store: store)
    ticket = create(:ticket, :draft, email_account: account)

    sign_in user
    visit ticket_path(id: ticket.id)
    expect(page).to have_content(I18n.t("tickets.show.trustpilot_bcc_label"))
  end

  it "hides the checkbox when the store has no Trustpilot address" do
    store = create(:shopify_store, user: user, company: user.companies.first, trustpilot_bcc_email: nil)
    account = create(:email_account, user: user, company: user.companies.first, shopify_store: store)
    ticket = create(:ticket, :draft, email_account: account)

    sign_in user
    visit ticket_path(id: ticket.id)
    expect(page).not_to have_content(I18n.t("tickets.show.trustpilot_bcc_label"))
    expect(page).to have_button(I18n.t("tickets.show.confirm_schedule"))
  end
end
```

- [ ] **Step 9: Run the system spec**

Run: `bundle exec rspec spec/system/tickets_spec.rb -e "Trustpilot BCC opt-in"`
Expected: PASS (2 examples).

- [ ] **Step 10: Lint + commit**

```bash
bin/rubocop app/controllers/tickets_controller.rb
git add db/migrate app/controllers/tickets_controller.rb app/views/tickets/show.html.erb config/locales db/schema.rb spec/requests/tickets_spec.rb spec/system/tickets_spec.rb
git commit -m "feat(tickets): opt-in Trustpilot BCC when confirming a draft"
```

---

### Task 3: Inject BCC at send time + record on the message

**Files:**
- Create: `db/migrate/20260718120003_add_bcc_to_messages.rb`
- Modify: `app/services/gmail_service.rb` (`send_message`, lines 26-41)
- Modify: `app/jobs/send_scheduled_email_job.rb` (`perform`, lines 20-41)
- Modify: `app/views/tickets/show.html.erb` (message rendering — add a badge where sent messages are shown)
- Modify: `config/locales/en.yml`, `config/locales/zh-TW.yml`, `config/locales/zh-CN.yml`
- Test: `spec/jobs/send_scheduled_email_job_spec.rb`

**Interfaces:**
- Consumes: `Ticket#bcc_trustpilot` (Task 2), `ShopifyStore#trustpilot_bcc_email` (Task 1).
- Produces: `GmailService#send_message(to:, subject:, body:, thread_id:, bcc: nil)`; `messages.bcc` column populated on sent replies.

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260718120003_add_bcc_to_messages.rb
class AddBccToMessages < ActiveRecord::Migration[8.1]
  def change
    # Records the actual BCC address on a sent reply (mirrors the existing `cc`
    # column) — the audit trail for Trustpilot review invitations.
    add_column :messages, :bcc, :string
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: `schema.rb` gains `t.string "bcc"` under `messages`.

- [ ] **Step 3: Add the `bcc:` param to GmailService**

In `app/services/gmail_service.rb`, replace `send_message` (lines 26-41):

```ruby
  def send_message(to:, subject:, body:, thread_id: nil, bcc: nil)
    from_addr = email_account.email
    mail = Mail.new
    mail.from = from_addr
    mail.to = to
    mail.bcc = bcc if bcc.present?
    mail.subject = subject
    mail.body = body
    mail.charset = "UTF-8"

    message = Google::Apis::GmailV1::Message.new(
      raw: mail.to_s,
      thread_id: thread_id
    )

    client.send_user_message("me", message)
  end
```

- [ ] **Step 4: Compute + pass + record bcc in the job**

In `app/jobs/send_scheduled_email_job.rb`, replace the block from line 20 (`gmail = GmailService.new(...)`) through the `ticket.messages.create!(...)` call:

```ruby
    gmail = GmailService.new(ticket.email_account)

    new_thread = ticket.gmail_thread_id.blank?
    subject = new_thread ? ticket.subject.to_s : "Re: #{ticket.subject}"

    bcc = ticket.bcc_trustpilot? ? ticket.email_account&.shopify_store&.trustpilot_bcc_email.presence : nil

    sent_message = gmail.send_message(
      to: ticket.customer_email,
      subject: subject,
      body: ticket.draft_reply,
      thread_id: ticket.gmail_thread_id,
      bcc: bcc
    )

    ticket.messages.create!(
      gmail_message_id: sent_message.id,
      from: ticket.email_account.email,
      to: ticket.customer_email,
      bcc: bcc,
      subject: subject,
      body: ticket.draft_reply,
      sent_at: Time.current,
      gmail_internal_date: (Time.current.to_f * 1000).to_i
    )
```

- [ ] **Step 5: Add i18n badge key (all three locales)**

`config/locales/en.yml` under `tickets.show:`:

```yaml
      trustpilot_invited_badge: "Trustpilot invite sent"
```

`config/locales/zh-TW.yml` under `tickets.show:`:

```yaml
      trustpilot_invited_badge: "已發送 Trustpilot 邀請"
```

`config/locales/zh-CN.yml` under `tickets.show:`:

```yaml
      trustpilot_invited_badge: "已发送 Trustpilot 邀请"
```

- [ ] **Step 6: Show the badge in the message list**

In `app/views/tickets/show.html.erb`, find where each message is rendered (the sent/received message loop). Locate the message header line that shows `message.from` / timestamp, and add, immediately after the from/subject header within the per-message block:

```erb
              <% if message.bcc.present? %>
                <span class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-green-100 text-green-800 text-xs font-medium">
                  <svg class="w-3 h-3" aria-hidden="true" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" d="M11.48 3.499a.562.562 0 0 1 1.04 0l2.125 5.111a.563.563 0 0 0 .475.345l5.518.442c.499.04.701.663.321.988l-4.204 3.602a.563.563 0 0 0-.182.557l1.285 5.385a.562.562 0 0 1-.84.61l-4.725-2.885a.562.562 0 0 0-.586 0L6.982 20.54a.562.562 0 0 1-.84-.61l1.285-5.386a.562.562 0 0 0-.182-.557l-4.204-3.602a.562.562 0 0 1 .321-.988l5.518-.442a.563.563 0 0 0 .475-.345L11.48 3.5Z" />
                  </svg>
                  <%= t("tickets.show.trustpilot_invited_badge") %>
                </span>
              <% end %>
```

(The exact insertion point is inside the message-rendering partial/loop — place it adjacent to the message metadata so it reads as an attribute of that sent reply. If messages are rendered by a partial, add it there instead; the `message` local is the per-message object.)

- [ ] **Step 7: Update the job spec (BCC behaviors)**

In `spec/jobs/send_scheduled_email_job_spec.rb`, add a context. The existing `before` already stubs `GmailService`; capture args to assert on `bcc`:

```ruby
context "Trustpilot BCC" do
  let(:store) { create(:shopify_store, trustpilot_bcc_email: "shop.com+abc@invite.trustpilot.com") }
  let(:email_account) { create(:email_account, email: "shop@gmail.com", token_expires_at: 1.hour.from_now, shopify_store: store) }

  def run_confirmed_ticket(bcc_flag)
    t = create(:ticket, :draft_confirmed, email_account: email_account,
               gmail_thread_id: "thread-t", customer_email: "buyer@example.com",
               scheduled_send_at: Time.current, scheduled_job_id: nil, bcc_trustpilot: bcc_flag)
    job = described_class.new(t.id)
    t.update!(scheduled_job_id: job.job_id)
    job.perform_now
    t.reload
  end

  it "passes the store address as BCC and records it when the flag is set" do
    gmail = instance_double(GmailService)
    allow(GmailService).to receive(:new).and_return(gmail)
    sent = Google::Apis::GmailV1::Message.new(id: "sent-1", thread_id: "thread-t")
    expect(gmail).to receive(:send_message)
      .with(hash_including(bcc: "shop.com+abc@invite.trustpilot.com")).and_return(sent)

    t = run_confirmed_ticket(true)
    expect(t.messages.last.bcc).to eq("shop.com+abc@invite.trustpilot.com")
  end

  it "sends no BCC when the flag is false" do
    gmail = instance_double(GmailService)
    allow(GmailService).to receive(:new).and_return(gmail)
    sent = Google::Apis::GmailV1::Message.new(id: "sent-2", thread_id: "thread-t")
    expect(gmail).to receive(:send_message).with(hash_including(bcc: nil)).and_return(sent)

    t = run_confirmed_ticket(false)
    expect(t.messages.last.bcc).to be_nil
  end

  it "sends no BCC when the flag is set but the store has no address" do
    store.update!(trustpilot_bcc_email: nil)
    gmail = instance_double(GmailService)
    allow(GmailService).to receive(:new).and_return(gmail)
    sent = Google::Apis::GmailV1::Message.new(id: "sent-3", thread_id: "thread-t")
    expect(gmail).to receive(:send_message).with(hash_including(bcc: nil)).and_return(sent)

    t = run_confirmed_ticket(true)
    expect(t.messages.last.bcc).to be_nil
  end
end
```

- [ ] **Step 8: Run the job spec**

Run: `bundle exec rspec spec/jobs/send_scheduled_email_job_spec.rb`
Expected: PASS (existing examples + 3 new).

- [ ] **Step 9: Full suite + lint**

Run: `bin/rubocop app/services/gmail_service.rb app/jobs/send_scheduled_email_job.rb && bundle exec rspec spec/models/shopify_store_spec.rb spec/requests/shopify_stores_spec.rb spec/requests/tickets_spec.rb spec/jobs/send_scheduled_email_job_spec.rb`
Expected: all PASS.

- [ ] **Step 10: Commit**

```bash
git add db/migrate app/services/gmail_service.rb app/jobs/send_scheduled_email_job.rb app/views/tickets/show.html.erb config/locales db/schema.rb spec/jobs/send_scheduled_email_job_spec.rb
git commit -m "feat(tickets): BCC Trustpilot at send time and record it on the message"
```

---

## Verification (end-to-end, before opening the PR)

- [ ] Run the full suite: `bundle exec rspec` — green, coverage ≥ 95%.
- [ ] `bin/rubocop` — no offenses.
- [ ] `bin/brakeman --no-pager` and `bin/bundler-audit` — clean.
- [ ] Manual smoke (optional, via `/run` or browser): set a Trustpilot address on a store; open a draft ticket for that store; the checkbox appears; confirm with it checked; verify the scheduled job (or a forced `perform_now` in console) would carry the BCC and stamp `messages.bcc`.
- [ ] Open PR into `staging` (per project workflow).

## Self-Review notes

- **Spec coverage:** store field + validation (Task 1) ✓; per-store settings UI + owner gate (Task 1) ✓; per-ticket opt-in default-off + visibility gate (Task 2) ✓; flag reset on re-confirm (Task 2) ✓; send-time injection + double-safety when unset (Task 3) ✓; audit record + badge (Task 3) ✓; i18n all locales (each task) ✓; system spec for Turbo form (Task 2) ✓.
- **Type consistency:** `trustpilot_bcc_email` (store), `bcc_trustpilot` (ticket boolean), `bcc` (message string), `send_message(..., bcc:)` — used identically across tasks.
