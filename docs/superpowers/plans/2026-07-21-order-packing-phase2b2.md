# Order Packing Phase 2B-2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Dianxiaomi-style package detail modal and the 待審核/待處理 edit + state operations — review/hold/back, edit address (sets address_overridden), edit per-item customs (sets customs_overridden), assign logistics channel, edit note, a tracking-readiness helper + blockers, and a cancelled-order warning.

**Architecture:** A Turbo-Frame modal (`#package-modal`) loaded from the list; a small Stimulus `modal` controller handles open/close/backdrop chrome. The modal renders a step bar (AASM state), left tabs (address/customs/logistics/note), and section forms that PATCH to new `PackagesController` member actions and re-render via `turbo_stream`. State transitions call AASM bang events. Fine-grained permissions (`package_review?`/`package_process?`) gate the actions.

**Tech Stack:** Rails 8.1, PostgreSQL UUID PKs, Hotwire (Turbo Frames + Streams + Stimulus), Tailwind, RSpec + FactoryBot.

## Global Constraints

- No new DB columns — reuse 2A/2B-1: `packages.shipping_address_snapshot` (jsonb) + `address_overridden`; `package_items` customs snapshot 6 cols + `customs_overridden`; `packages.logistics_channel_id`; `packages.note`.
- RSpec + FactoryBot, no fixtures; ≥95% line coverage. No mocks.
- Turbo-driven UI ships a system spec in the same commit.
- i18n keys in all three locales (`config/locales/en.yml` ~L621 `packages:`, `zh-TW.yml`/`zh-CN.yml` ~L619). Permission labels already exist (`invitations.permission_labels.package_*`).
- Route helpers take keyword ids under the `scope "(:locale)"` wrapper.
- Never commit to `main`/`staging`; work on `feature/order-packing-phase2b2` (off `origin/staging`, includes 2A+2B-1).
- Design: `docs/superpowers/specs/2026-07-21-order-packing-phase2b2-design.md`.
- **2B-2 scope:** detail modal + review/process edits + state ops (submit_review/hold/unhold/back_to_review). NOT folding (拆分 = 2B-3), NOT tracking application (申請運單號 + `apply_tracking` action = 2C; 2B-2 only provides `ready_for_tracking?` helper), NOT prev/next nav.
- **Editing does NOT enforce required-together** — customs/address save partial drafts freely; completeness is only checked by `ready_for_tracking?` at push time (2C). Different from Phase 1 product_customs.

## Key existing facts (verified — trust these)

- `PackagesController` (app/controllers/packages_controller.rb) has `index` + `sync`, `authorize_page!` override (any packing permission), `scoped_packages`. Routes: `resources :packages, only: [:index] do post :sync, on: :collection end`.
- `Package` AASM events: `submit_review!` (pending_review→pending_process), `back_to_review!` (pending_process→pending_review), `hold!` (from the 4 pre-shipped states → held, sets held_from), `unhold!` (held → held_from state), `back_to_process!`, `apply_tracking!`, `refund!`. Bang events persist. Invalid → `AASM::InvalidTransition`.
- `PackageItem#fully_refunded?` = refunded_quantity >= quantity.
- `Membership`: `AVAILABLE_PERMISSIONS` includes package_review/process/shipping; `PACKING_PERMISSIONS`; `any_packing_permission?` (owner OR any). `owner?` from enum. `permissions` is a jsonb array. NO fine-grained review/process helpers yet.
- Logistics: `current_company.logistics_accounts.find_by(provider: "raydo")` → `@account.logistics_channels.order(:name)`. LogisticsChannel has `name`, `product_shortname`.
- Modal template to mirror: `app/views/tickets/_order_picker_modal.html.erb` + `app/javascript/controllers/order_picker_controller.js` (open/close/backdrop). Row-edit: `app/javascript/controllers/row_edit_controller.js` + `app/views/product_customs/_row.html.erb` + `app/controllers/product_variants_controller.rb#update` + `app/views/product_variants/update.turbo_stream.erb`.
- Order shipping address lives in `order.shopify_data["shipping_address"]` (keys: name/phone/address1/address2/city/province/zip/country/country_code). `order.shopify_data["cancelled_at"]` for cancellation.
- Package show list link + modal mount go in `app/views/packages/index.html.erb` / `_package_row.html.erb`.
- Specs: request uses `sign_in user` (Devise), system uses `sign_in_as(user)`. Factories: `:package(shopify_store:, order:, aasm_state:, number:)`, `:package_item(package:, sku:, quantity:, refunded_quantity:)`, `:membership(user:, company:, role:, permissions:)`, `:order(customer:, shopify_store:, name:, shopify_data:)`.

## File Structure

- `app/models/membership.rb` — `package_review?`/`package_process?` (Task 1)
- `app/models/package.rb` — `ready_for_tracking?`, `tracking_blockers`, `order_cancelled?` (Task 2)
- `app/controllers/packages_controller.rb`, `config/routes.rb` — show + member actions (Tasks 3-7)
- `app/javascript/controllers/modal_controller.js` (Task 3)
- `app/views/packages/show.html.erb`, `_modal.html.erb`, `_step_bar.html.erb`, `_address_section.html.erb`, `_customs_section.html.erb`, `_logistics_section.html.erb`, `_note_section.html.erb`, `_actions.html.erb`, various `*.turbo_stream.erb` (Tasks 3-7)
- `app/views/packages/index.html.erb`, `_package_row.html.erb` — modal mount + list link + cancel badge (Tasks 3, 8)
- `config/locales/*.yml`, specs alongside.

---

### Task 1: Fine-grained packing permission helpers

**Files:**
- Modify: `app/models/membership.rb`
- Test: `spec/models/membership_spec.rb`

**Interfaces:**
- Produces: `Membership#package_review?` (owner OR has "package_review"), `#package_process?` (owner OR has "package_process"). Consumed by Tasks 4-7 controller gates.

- [ ] **Step 1: Failing spec**
```ruby
describe "fine-grained packing permissions" do
  let(:company) { create(:company) }
  it "package_review? is true for owner, for a member with the perm, false otherwise" do
    expect(create(:membership, company: company, role: :owner).package_review?).to be(true)
    m = create(:membership, company: company, role: :member, permissions: ["package_review"], group: create(:group, company: company))
    expect(m.package_review?).to be(true)
    m2 = create(:membership, company: company, role: :member, permissions: ["package_process"], group: create(:group, company: company))
    expect(m2.package_review?).to be(false)
  end
  it "package_process? mirrors it for the process permission" do
    expect(create(:membership, company: company, role: :owner).package_process?).to be(true)
    m = create(:membership, company: company, role: :member, permissions: ["package_process"], group: create(:group, company: company))
    expect(m.package_process?).to be(true)
    m2 = create(:membership, company: company, role: :member, permissions: ["package_review"], group: create(:group, company: company))
    expect(m2.package_process?).to be(false)
  end
end
```
(Match how existing membership specs build members w/ group — mirror the `any_packing_permission?` spec's construction.)

- [ ] **Step 2: Run — FAIL.** `bundle exec rspec spec/models/membership_spec.rb -e "fine-grained"`

- [ ] **Step 3: Implement** in `app/models/membership.rb` (after `any_packing_permission?`):
```ruby
  def package_review?
    owner? || permissions.include?("package_review")
  end

  def package_process?
    owner? || permissions.include?("package_process")
  end
```

- [ ] **Step 4: Run — PASS.**

- [ ] **Step 5: Commit**
```bash
bin/rubocop app/models/membership.rb
git add app/models/membership.rb spec/models/membership_spec.rb
git commit -m "feat(packing): fine-grained package_review?/package_process? membership helpers"
```

---

### Task 2: Package readiness + cancellation helpers

**Files:**
- Modify: `app/models/package.rb`
- Test: `spec/models/package_spec.rb`

**Interfaces:**
- Produces: `Package#ready_for_tracking?` (bool), `#tracking_blockers` (Array<String> — human-readable missing items), `#order_cancelled?` (bool), plus small predicates `#address_complete?`, `#logistics_assigned?`, `#customs_complete?`. Consumed by Tasks 3/8 (UI green checks + blockers + cancel badge) and 2C (apply-tracking gate).

- [ ] **Step 1: Failing spec**
```ruby
describe "tracking readiness" do
  let(:store) { create(:shopify_store, package_prefix: "XM", package_number_start: 1) }
  let(:order) { create(:order, shopify_store: store, financial_status: "paid") }
  let(:channel) { create(:logistics_channel) }

  def complete_package
    pkg = create(:package, shopify_store: store, order: order, aasm_state: "pending_process", number: 1,
                 logistics_channel: channel,
                 shipping_address_snapshot: { "name" => "J", "country_code" => "US", "address1" => "1 St", "city" => "NYC" })
    create(:package_item, package: pkg, sku: "A", quantity: 2, refunded_quantity: 0,
           customs_name_zh: "積木", customs_name_en: "Blocks", declared_value_usd: 5, customs_weight_grams: 100)
    pkg
  end

  it "is ready when address, logistics and customs are all complete" do
    expect(complete_package.ready_for_tracking?).to be(true)
  end

  it "reports a blocker when logistics is unassigned" do
    pkg = complete_package
    pkg.update!(logistics_channel: nil)
    expect(pkg.ready_for_tracking?).to be(false)
    expect(pkg.tracking_blockers.join).to match(/logistic/i).or match(/物流/)
  end

  it "reports a blocker when the address is incomplete" do
    pkg = complete_package
    pkg.update!(shipping_address_snapshot: { "name" => "J" })  # missing country/address1/city
    expect(pkg.ready_for_tracking?).to be(false)
    expect(pkg.tracking_blockers).to be_present
  end

  it "reports a blocker for an item missing required customs" do
    pkg = complete_package
    pkg.package_items.first.update!(declared_value_usd: nil)
    expect(pkg.ready_for_tracking?).to be(false)
    expect(pkg.tracking_blockers).to be_present
  end

  it "ignores fully-refunded items in the customs check" do
    pkg = complete_package
    create(:package_item, package: pkg, sku: "B", quantity: 1, refunded_quantity: 1)  # fully refunded, no customs
    expect(pkg.ready_for_tracking?).to be(true)
  end
end

describe "order_cancelled?" do
  let(:store) { create(:shopify_store) }
  it "is true when the order is cancelled and not fully refunded" do
    order = create(:order, shopify_store: store, financial_status: "paid", shopify_data: { "cancelled_at" => "2026-07-20T00:00:00Z" })
    pkg = create(:package, shopify_store: store, order: order, number: 1)
    expect(pkg.order_cancelled?).to be(true)
  end
  it "is false when not cancelled" do
    order = create(:order, shopify_store: store, financial_status: "paid", shopify_data: {})
    expect(create(:package, shopify_store: store, order: order, number: 2).order_cancelled?).to be(false)
  end
  it "is false when fully refunded (that path is 已退款, not cancelled)" do
    order = create(:order, shopify_store: store, financial_status: "refunded", shopify_data: { "cancelled_at" => "2026-07-20T00:00:00Z" })
    expect(create(:package, shopify_store: store, order: order, number: 3).order_cancelled?).to be(false)
  end
end
```

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement** in `app/models/package.rb`:
```ruby
  ADDRESS_REQUIRED = %w[name country_code address1 city].freeze

  def address_complete?
    ADDRESS_REQUIRED.all? { |k| shipping_address_snapshot[k].present? }
  end

  def logistics_assigned?
    logistics_channel_id.present?
  end

  # Customs is complete when every not-fully-refunded item has the 4 required
  # customs fields. Fully-refunded items are excluded (they won't ship).
  def customs_complete?
    package_items.reject(&:fully_refunded?).all? do |item|
      item.customs_name_zh.present? && item.customs_name_en.present? &&
        item.declared_value_usd.present? && item.customs_weight_grams.present?
    end
  end

  def ready_for_tracking?
    address_complete? && logistics_assigned? && customs_complete?
  end

  # Human-readable list of what's missing to advance to tracking application.
  def tracking_blockers
    blockers = []
    blockers << I18n.t("packages.blockers.address") unless address_complete?
    blockers << I18n.t("packages.blockers.logistics") unless logistics_assigned?
    package_items.reject(&:fully_refunded?).each do |item|
      next if item.customs_name_zh.present? && item.customs_name_en.present? &&
              item.declared_value_usd.present? && item.customs_weight_grams.present?
      blockers << I18n.t("packages.blockers.customs", sku: item.sku)
    end
    blockers
  end

  def order_cancelled?
    order.shopify_data["cancelled_at"].present? && order.financial_status != "refunded"
  end
```
Add i18n (all three locales) under `packages:`:
```yaml
    blockers:
      address: "Shipping address incomplete"   # zh-TW 收件地址不完整 / zh-CN 收货地址不完整
      logistics: "No logistics channel assigned"  # 未分配物流渠道 / 未分配物流渠道
      customs: "SKU %{sku} missing customs info"   # SKU %{sku} 報關資訊不完整 / SKU %{sku} 报关信息不完整
    order_cancelled: "Order cancelled"   # 訂單已取消 / 订单已取消
```

- [ ] **Step 4: Run — PASS.**

- [ ] **Step 5: Commit**
```bash
bin/rubocop app/models/package.rb
git add app/models/package.rb config/locales spec/models/package_spec.rb
git commit -m "feat(packing): ready_for_tracking?/tracking_blockers/order_cancelled? helpers"
```

---

### Task 3: Detail modal shell + read-only package show

**Files:**
- Create: `app/javascript/controllers/modal_controller.js`
- Create: `app/views/packages/show.html.erb`, `app/views/packages/_modal.html.erb`, `_step_bar.html.erb`, `_address_section.html.erb`, `_customs_section.html.erb`, `_logistics_section.html.erb`, `_note_section.html.erb`, `_order_info.html.erb`
- Modify: `app/controllers/packages_controller.rb` (show + set_package), `config/routes.rb`, `app/views/packages/index.html.erb` (modal frame mount + list link), `app/views/packages/_package_row.html.erb` (package_code → link targeting the modal frame)
- Modify: `config/locales/*.yml`
- Test: `spec/requests/packages_spec.rb`, `spec/system/packages_spec.rb`

**Interfaces:**
- Produces: `GET package_path(id)` renders the detail into `<turbo-frame id="package-modal">`; a Stimulus `modal` controller opens/closes the dialog chrome. Read-only sections (address/customs/logistics/note) + step bar + order info. Consumed by Tasks 4-8 (they add edit forms + actions into these sections).

- [ ] **Step 1: Routes + controller show**

`config/routes.rb` — extend packages:
```ruby
    resources :packages, only: [ :index, :show ] do
      collection do
        post :sync
      end
    end
```
`PackagesController`:
```ruby
  before_action :set_package, only: :show

  def show
    render partial: "modal", locals: { package: @package } if turbo_frame_request?
  end
```
Add private `set_package`:
```ruby
  def set_package
    @package = scoped_packages.includes(:order, :package_items, :logistics_channel, :shopify_store).find(params[:id])
  end
```
`turbo_frame_request?` is a Turbo helper (available). For a non-frame GET (direct URL), fall back to rendering the full `show.html.erb` (which wraps the modal partial). Use:
```ruby
  def show
    respond_to do |format|
      format.html
    end
  end
```
and have `show.html.erb` render the frame + modal partial so both a direct visit and a frame request work; the frame request only swaps the frame's inner content.

- [ ] **Step 2: Stimulus modal controller** `app/javascript/controllers/modal_controller.js` (mirror order_picker open/close/backdrop):
```js
import { Controller } from "@hotwired/stimulus"

// Opens when the turbo-frame it wraps gets content; closes on backdrop/✕/Esc.
export default class extends Controller {
  static targets = ["dialog", "backdrop"]

  connect() {
    this._esc = (e) => { if (e.key === "Escape") this.close() }
    document.addEventListener("keydown", this._esc)
  }
  disconnect() { document.removeEventListener("keydown", this._esc) }

  open() {
    this.element.classList.remove("hidden")
    document.body.classList.add("overflow-hidden")
  }
  close() {
    this.element.classList.add("hidden")
    document.body.classList.remove("overflow-hidden")
    const frame = document.getElementById("package-modal")
    if (frame) frame.innerHTML = ""
  }
  backdropClick(event) { if (event.target === this.backdropTarget) this.close() }
}
```

- [ ] **Step 3: Modal mount in the list** — in `app/views/packages/index.html.erb`, near the bottom, add the modal wrapper + frame:
```erb
<div data-controller="modal" class="hidden fixed inset-0 z-50" data-modal-target="dialog">
  <div data-modal-target="backdrop" data-action="click->modal#backdropClick" class="fixed inset-0 bg-black/50"></div>
  <div class="fixed inset-0 flex items-start justify-center pt-[6vh] px-4 pointer-events-none">
    <div class="bg-white rounded-xl shadow-2xl w-full max-w-5xl max-h-[88vh] overflow-y-auto pointer-events-auto">
      <%= turbo_frame_tag "package-modal" %>
    </div>
  </div>
</div>
```
And a tiny Stimulus hook so that when the frame receives content the dialog opens — simplest: add `data-action="turbo:frame-load->modal#open"` to the modal root element. So the root becomes:
```erb
<div data-controller="modal" data-modal-target="dialog"
     data-action="turbo:frame-load@window->modal#open"
     class="hidden fixed inset-0 z-50"> ... </div>
```
(The `turbo:frame-load` fires when `#package-modal` loads content; guard in the handler that the loaded frame id is `package-modal` — add that check to `open()` or bind narrowly. Simplest robust approach: in `open()`, do nothing unless the frame has children.)

- [ ] **Step 4: List link opens the modal** — in `_package_row.html.erb`, change the package_code cell to a link targeting the frame:
```erb
<%= link_to package.package_code, package_path(id: package.id),
    data: { turbo_frame: "package-modal" },
    class: "text-blue-600 hover:underline font-medium" %>
```

- [ ] **Step 5: `_modal.html.erb`** — the frame content: header (package_code, source, ✕ close), top info strip (seller/store, buyer email/name, order total), step bar (render `_step_bar`), left tabs + right section content (render the 4 section partials, read-only), bottom order info table (`_order_info`), bottom actions placeholder (Task 4 fills). Wrap in `turbo_frame_tag "package-modal"`. Use Tailwind responsive classes: left tabs `hidden md:flex md:flex-col` + a horizontal tab strip `flex md:hidden overflow-x-auto` for mobile; sections stack on mobile. Tab switching via a small inline Stimulus `tabs` controller or `data-action` toggling `hidden` on section divs (implement a minimal `tabs_controller.js` OR reuse show/hide via `nav-group` idiom — pick one and keep it consistent). The ✕ button: `data-action="click->modal#close"`.

- [ ] **Step 6: `_step_bar.html.erb`** — render the 5 main states as a horizontal chevron bar; highlight `package.aasm_state`; show held/refunded as a distinct pill. Read-only. Use `t("packages.states.*")`.

- [ ] **Step 7: Section partials (read-only)** — `_address_section` shows the `shipping_address_snapshot` fields; `_customs_section` shows each package_item's customs snapshot (+ refunded badge from 2B-1); `_logistics_section` shows `package.logistics_channel&.name || "—"`; `_note_section` shows `package.note`. `_order_info` shows order name + line items table. Each section has an "Edit" affordance placeholder (Tasks 5-7 wire the forms). Give each section a stable dom id (e.g. `dom_id(package, :address)`) so later tasks can `turbo_stream.replace` it.

- [ ] **Step 8: i18n** (all three locales) under `packages:` — modal labels: `detail_title` ("Package %{code} detail"), `tabs: { address:, customs:, logistics:, note: }`, `edit`, `save`, `cancel`, `seller`, `buyer`, `buyer_name`, `order_total`, `source`, `close`, address field labels, etc. (Add the full set the partials reference.)

- [ ] **Step 9: Request spec** `spec/requests/packages_spec.rb`:
```ruby
describe "GET /packages/:id (detail)" do
  it "renders the package detail for a user with a packing permission" do
    pkg = create(:package, shopify_store: store, order: create(:order, shopify_store: store), aasm_state: "pending_process", number: 10)
    get package_path(id: pkg.id)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(pkg.package_code)
  end
  it "does not leak another company's package" do
    other = create(:user); other_store = create(:shopify_store, user: other, company: other.companies.first)
    foreign = create(:package, shopify_store: other_store, order: create(:order, shopify_store: other_store), number: 99)
    get package_path(id: foreign.id)
    expect(response).to have_http_status(:not_found).or redirect_to(authenticated_root_path)
  end
  it "denies a member without any packing permission" do
    member = create(:user); create(:membership, user: member, company: company, role: :member, permissions: ["orders"])
    sign_out user; sign_in member
    pkg = create(:package, shopify_store: store, order: create(:order, shopify_store: store), number: 11)
    get package_path(id: pkg.id)
    expect(response).to redirect_to(authenticated_root_path)
  end
end
```
(A cross-company `find` on `scoped_packages` raises RecordNotFound → 404; confirm the app renders 404 or handles it — if AdminController rescues RecordNotFound to a redirect, assert that.)

- [ ] **Step 10: System spec** `spec/system/packages_spec.rb` (`:js`): visit the list, click a package_code link, the modal opens showing the detail (package_code, step bar, tabs); clicking a tab shows that section; ✕ closes it. (Run `bin/rails tailwindcss:build` first; if it fails only for env/browser reasons report DONE_WITH_CONCERNS.)

- [ ] **Step 11: Run + commit**
```bash
bundle exec rspec spec/requests/packages_spec.rb spec/system/packages_spec.rb
bin/rubocop app/controllers/packages_controller.rb
git add app/controllers/packages_controller.rb config/routes.rb app/views/packages app/javascript/controllers/modal_controller.js config/locales spec
git commit -m "feat(packing): package detail modal (Turbo Frame) with step bar and read-only sections"
```

---

### Task 4: State operations (review / hold / unhold / back_to_review)

**Files:**
- Modify: `app/controllers/packages_controller.rb`, `config/routes.rb`
- Create: `app/views/packages/_actions.html.erb`, `app/views/packages/transition.turbo_stream.erb`
- Modify: `app/views/packages/_modal.html.erb` (render actions)
- Modify: `config/locales/*.yml`
- Test: `spec/requests/packages_spec.rb`, `spec/system/packages_spec.rb`

**Interfaces:**
- Consumes: Task 1 gates, Task 3 modal. Produces: `PATCH transition_package_path(id, event:)` runs an AASM event, re-renders the modal via turbo_stream.

- [ ] **Step 1: Route** (member):
```ruby
    resources :packages, only: [ :index, :show ] do
      member { patch :transition }
      collection { post :sync }
    end
```

- [ ] **Step 2: Controller action**
```ruby
  REVIEW_EVENTS  = %w[submit_review back_to_review].freeze
  PROCESS_EVENTS = %w[hold unhold back_to_process].freeze

  def transition
    set_package
    event = params[:event].to_s
    unless REVIEW_EVENTS.include?(event) || PROCESS_EVENTS.include?(event)
      return redirect_to(packages_path, alert: t("packages.invalid_action"))
    end
    unless authorized_for_event?(event)
      return redirect_to(packages_path, alert: t("companies.no_permission"))
    end
    @package.public_send("#{event}!")
    respond_to do |format|
      format.turbo_stream { render :transition }
      format.html { redirect_to packages_path(state: @package.aasm_state), notice: t("packages.transitioned") }
    end
  rescue AASM::InvalidTransition
    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.replace("package-modal", partial: "packages/modal", locals: { package: @package.reload }), status: :unprocessable_entity }
      format.html { redirect_to packages_path, alert: t("packages.invalid_transition") }
    end
  end

  private

  def authorized_for_event?(event)
    m = current_membership
    return false unless m
    REVIEW_EVENTS.include?(event) ? m.package_review? : m.package_process?
  end
```
(Note: `set_package` also runs for :transition — add `:transition` to its before_action list or call it inline as above. Keep one approach consistent.)

- [ ] **Step 3: Actions partial** `_actions.html.erb` — render buttons conditional on state + permission:
```erb
<% if package.pending_review? && current_membership&.package_review? %>
  <%= button_to t("packages.actions.review"), transition_package_path(id: package.id, event: "submit_review"),
      method: :patch, class: "px-4 py-2 bg-green-600 text-white text-sm rounded hover:bg-green-700" %>
<% end %>
<% if package.pending_process? && current_membership&.package_review? %>
  <%= button_to t("packages.actions.back_to_review"), transition_package_path(id: package.id, event: "back_to_review"),
      method: :patch, class: "px-4 py-2 bg-blue-500 text-white text-sm rounded hover:bg-blue-600" %>
<% end %>
<% if package.held? && current_membership&.package_process? %>
  <%= button_to t("packages.actions.unhold"), transition_package_path(id: package.id, event: "unhold"),
      method: :patch, class: "px-4 py-2 bg-yellow-600 text-white text-sm rounded hover:bg-yellow-700" %>
<% elsif %w[pending_review pending_process].include?(package.aasm_state) && current_membership&.package_process? %>
  <%= button_to t("packages.actions.hold"), transition_package_path(id: package.id, event: "hold"),
      method: :patch, class: "px-4 py-2 bg-gray-500 text-white text-sm rounded hover:bg-gray-600" %>
<% end %>
```
(All button_to's target the modal frame so the turbo_stream response updates it: add `form: { data: { turbo_frame: "package-modal" } }` or rely on the turbo_stream replace of `#package-modal`. Use `turbo_stream.replace "package-modal"` in the response so the whole modal re-renders with the new state.)

- [ ] **Step 4: `transition.turbo_stream.erb`**
```erb
<%= turbo_stream.replace "package-modal", partial: "packages/modal", locals: { package: @package } %>
```

- [ ] **Step 5: Render actions in `_modal.html.erb`** — add `<%= render "packages/actions", package: package %>` in the bottom action bar.

- [ ] **Step 6: i18n** (all three locales) `packages.actions.{review,back_to_review,hold,unhold}`, `packages.{invalid_action,invalid_transition,transitioned}`.

- [ ] **Step 7: Request specs**
  - member with package_review can submit_review (pending_review→pending_process); a member with only package_process CANNOT submit_review (redirect/no_permission).
  - member with package_process can hold; a member with only package_review cannot hold.
  - an invalid event (e.g. `ship` from pending_review, or an unlisted event) is rejected (422 / alert, not 500).
  - hold sets held_from; unhold restores.

- [ ] **Step 8: System spec** — open a pending_review package's modal, click 審核, the step bar advances to pending_process; hold shows held.

- [ ] **Step 9: Run + commit**
```bash
bundle exec rspec spec/requests/packages_spec.rb spec/system/packages_spec.rb
bin/rubocop app/controllers/packages_controller.rb
git add app/controllers/packages_controller.rb config/routes.rb app/views/packages config/locales spec
git commit -m "feat(packing): review/hold/unhold/back_to_review state actions in the detail modal"
```

---

### Task 5: Edit shipping address (sets address_overridden)

**Files:**
- Modify: `app/controllers/packages_controller.rb`, `config/routes.rb`
- Modify: `app/views/packages/_address_section.html.erb` (add edit form)
- Create: `app/views/packages/update_address.turbo_stream.erb`
- Modify: `config/locales/*.yml`
- Test: `spec/requests/packages_spec.rb`, `spec/system/packages_spec.rb`

**Interfaces:**
- Consumes: Task 1 (`package_process?`), Task 3 (address section). Produces: `PATCH update_address_package_path(id)` writes the jsonb snapshot + sets `address_overridden = true`, re-renders the address section.

- [ ] **Step 1: Route** — add `patch :update_address` to the member block.

- [ ] **Step 2: Controller**
```ruby
  ADDRESS_KEYS = %w[name phone address1 address2 city province zip country country_code company tax_id].freeze

  def update_address
    set_package
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?
    snapshot = ADDRESS_KEYS.index_with { |k| params.dig(:address, k).to_s }
    @package.update!(shipping_address_snapshot: snapshot, address_overridden: true)
    respond_to do |format|
      format.turbo_stream { render :update_address }
      format.html { redirect_to package_path(id: @package.id), notice: t("packages.address_saved") }
    end
  end
```
(Merge with existing snapshot rather than overwrite if you want to preserve unlisted keys — but the form submits all address keys, so a full replace with the known keys is fine. Use `.presence` handling so blank optionals store "" consistently.)

- [ ] **Step 3: Edit form in `_address_section.html.erb`** — a toggle (read view + edit form). Edit form is a `form_with url: update_address_package_path(id: package.id), method: :patch, data: { turbo_frame: "package-modal" }` with inputs named `address[name]`, `address[address1]`, etc. On save, the turbo_stream replaces the address section. Required fields (name/country_code/address1/city) get a visual `*` but are NOT server-enforced here (completeness is `ready_for_tracking?`).

- [ ] **Step 4: `update_address.turbo_stream.erb`**
```erb
<%= turbo_stream.replace dom_id(@package, :address), partial: "packages/address_section", locals: { package: @package } %>
```

- [ ] **Step 5: i18n** address field labels + `packages.address_saved` (all three locales).

- [ ] **Step 6: Request specs**
  - package_process member updates the address → snapshot persisted + `address_overridden` true.
  - a member without package_process is denied.
  - after override, a re-sync does NOT overwrite (integration: set the order's shipping_address differently, run `PackageAutoBuilder.new(order).call`, assert snapshot preserved — reuses 2B-1 behavior, proves the flag wiring).

- [ ] **Step 7: System spec** — edit the address in the modal, save, the section shows the new value; the address tab shows its green check when complete.

- [ ] **Step 8: Run + commit**
```bash
bundle exec rspec spec/requests/packages_spec.rb spec/system/packages_spec.rb
bin/rubocop app/controllers/packages_controller.rb
git add app/controllers/packages_controller.rb config/routes.rb app/views/packages config/locales spec
git commit -m "feat(packing): edit shipping address (sets address_overridden) in the modal"
```

---

### Task 6: Edit per-item customs (sets customs_overridden)

**Files:**
- Modify: `app/controllers/packages_controller.rb`, `config/routes.rb`
- Modify: `app/views/packages/_customs_section.html.erb` (per-item edit, row-edit pattern)
- Create: `app/views/packages/_customs_row.html.erb`, `app/views/packages/update_item.turbo_stream.erb`
- Modify: `config/locales/*.yml`
- Test: `spec/requests/packages_spec.rb`, `spec/system/packages_spec.rb`

**Interfaces:**
- Consumes: Task 1 (`package_process?`), Task 3 (customs section). Produces: `PATCH update_item_package_path(id, item_id:)` writes the item's 6 customs fields + sets `customs_overridden = true`, re-renders that row.

- [ ] **Step 1: Route** — add `patch :update_item` to the member block (with `item_id` param).

- [ ] **Step 2: Controller**
```ruby
  def update_item
    set_package
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?
    @item = @package.package_items.find(params[:item_id])
    @item.update!(customs_item_params.merge(customs_overridden: true))
    respond_to do |format|
      format.turbo_stream { render :update_item }
      format.html { redirect_to package_path(id: @package.id), notice: t("packages.item_saved") }
    end
  end

  def customs_item_params
    params.require(:package_item).permit(:customs_name_zh, :customs_name_en, :declared_value_usd, :hs_code, :import_hs_code, :customs_weight_grams)
  end
```

- [ ] **Step 3: Row-edit UI** — mirror `product_customs/_row.html.erb` + `row_edit_controller.js`. `_customs_row.html.erb` is a `<tr>` with `data-controller="row-edit" data-row-edit-url-value="<%= update_item_package_path(id: package.id, item_id: item.id) %>"`; each of the 6 fields is an `<input ... name="package_item[...]" data-row-edit-target="field">`; a `type="button" data-action="click->row-edit#save"` save button. (row_edit_controller.js already exists and is generic — reuse as-is.) The customs section renders a table of `_customs_row` for each item.

- [ ] **Step 4: `update_item.turbo_stream.erb`**
```erb
<%= turbo_stream.replace dom_id(@item), partial: "packages/customs_row", locals: { package: @package, item: @item } %>
```
(Ensure `_customs_row` sets `id="<%= dom_id(item) %>"` on the `<tr>`.)

- [ ] **Step 5: i18n** customs column labels + `packages.item_saved` (all three locales).

- [ ] **Step 6: Request specs**
  - package_process member updates an item's customs → 6 fields persisted + `customs_overridden` true.
  - member without package_process denied.
  - after override, re-sync does NOT overwrite that item's customs (integration reusing 2B-1).

- [ ] **Step 7: System spec** — edit an item's customs in the modal, save, the row reflects it; the customs tab green check appears when all not-refunded items are complete.

- [ ] **Step 8: Run + commit**
```bash
bundle exec rspec spec/requests/packages_spec.rb spec/system/packages_spec.rb
bin/rubocop app/controllers/packages_controller.rb
git add app/controllers/packages_controller.rb config/routes.rb app/views/packages config/locales spec
git commit -m "feat(packing): edit per-item customs (sets customs_overridden) in the modal"
```

---

### Task 7: Assign logistics channel + edit note

**Files:**
- Modify: `app/controllers/packages_controller.rb`, `config/routes.rb`
- Modify: `app/views/packages/_logistics_section.html.erb`, `_note_section.html.erb`
- Create: `app/views/packages/update_logistics.turbo_stream.erb`, `update_note.turbo_stream.erb`
- Modify: `config/locales/*.yml`
- Test: `spec/requests/packages_spec.rb`, `spec/system/packages_spec.rb`

**Interfaces:**
- Consumes: Task 1 (`package_process?`), Task 3 sections. Produces: `PATCH update_logistics_package_path(id)` sets `logistics_channel_id` (company-scoped, cross-company guard); `PATCH update_note_package_path(id)` sets `note`.

- [ ] **Step 1: Routes** — add `patch :update_logistics`, `patch :update_note` to the member block.

- [ ] **Step 2: Controller**
```ruby
  def update_logistics
    set_package
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?
    channel_id = params[:logistics_channel_id].presence
    channel = channel_id && company_logistics_channels.find_by(id: channel_id)
    if channel_id && channel.nil?
      return redirect_to(package_path(id: @package.id), alert: t("packages.invalid_channel"))
    end
    @package.update!(logistics_channel_id: channel&.id)
    respond_to do |format|
      format.turbo_stream { render :update_logistics }
      format.html { redirect_to package_path(id: @package.id), notice: t("packages.logistics_saved") }
    end
  end

  def update_note
    set_package
    return redirect_to(packages_path, alert: t("companies.no_permission")) unless current_membership&.package_process?
    @package.update!(note: params[:note].to_s)
    respond_to do |format|
      format.turbo_stream { render :update_note }
      format.html { redirect_to package_path(id: @package.id), notice: t("packages.note_saved") }
    end
  end

  # Cross-company safety: only this company's raydo channels are assignable.
  def company_logistics_channels
    account = current_company.logistics_accounts.find_by(provider: "raydo")
    account ? account.logistics_channels.order(:name) : LogisticsChannel.none
  end
  helper_method :company_logistics_channels
```

- [ ] **Step 3: Logistics section** — read view shows `package.logistics_channel&.name || "—"`; edit is a `form_with url: update_logistics_package_path(id: package.id), method: :patch, data: { turbo_frame: "package-modal" }` with a `<select name="logistics_channel_id">` populated from `company_logistics_channels` (option label `"#{c.name} — #{c.product_shortname}"`, blank option to unassign). Note section: a textarea `name="note"` posting to `update_note_package_path`.

- [ ] **Step 4: turbo_stream templates** — each replaces its section via `dom_id(@package, :logistics)` / `dom_id(@package, :note)`.

- [ ] **Step 5: i18n** logistics/note labels + saved notices + `packages.invalid_channel` (all three locales).

- [ ] **Step 6: Request specs**
  - assign a company channel → `logistics_channel_id` set; unassign (blank) → nil.
  - **cross-company guard**: passing another company's channel id → rejected (alert), `logistics_channel_id` unchanged.
  - member without package_process denied for both actions.
  - note update persists.

- [ ] **Step 7: System spec** — pick a channel in the modal → logistics section + tab check update; edit note → persists.

- [ ] **Step 8: Run + commit**
```bash
bundle exec rspec spec/requests/packages_spec.rb spec/system/packages_spec.rb
bin/rubocop app/controllers/packages_controller.rb
git add app/controllers/packages_controller.rb config/routes.rb app/views/packages config/locales spec
git commit -m "feat(packing): assign logistics channel (company-scoped) and edit note in the modal"
```

---

### Task 8: Tracking-readiness display + cancelled-order warning

**Files:**
- Modify: `app/views/packages/_modal.html.erb` (tab green checks + blockers panel), `_package_row.html.erb` + `_customs_section`/section partials (cancel badge)
- Modify: `config/locales/*.yml`
- Test: `spec/requests/packages_spec.rb`, `spec/system/packages_spec.rb`

**Interfaces:**
- Consumes: Task 2 helpers (`ready_for_tracking?`, `tracking_blockers`, `order_cancelled?`, `address_complete?`, `logistics_assigned?`, `customs_complete?`), Task 3 modal, Task 5-7 sections. Produces: the UI wiring that shows green checks per tab, a blockers list when not ready, and a cancel warning on the list + modal.

- [ ] **Step 1: Tab green checks** — in `_modal.html.erb`, each left tab shows a green check when its section is complete: address tab → `package.address_complete?`; customs tab → `package.customs_complete?`; logistics tab → `package.logistics_assigned?`. (note tab has no completeness.)

- [ ] **Step 2: Blockers panel** — when `package.pending_process?` and `!package.ready_for_tracking?`, show a panel listing `package.tracking_blockers` (so the user sees what's missing before the 2C apply-tracking step). When ready, show a "ready" affordance (the actual 申請運單號 button is 2C).

- [ ] **Step 3: Cancel warning** — when `package.order_cancelled?`, show a red "Order cancelled" banner at the top of the modal AND a red badge on the list row (`_package_row.html.erb`). Use `t("packages.order_cancelled")`.

- [ ] **Step 4: Failing request spec**
```ruby
describe "readiness + cancel display" do
  it "shows blockers for an incomplete pending_process package" do
    pkg = create(:package, shopify_store: store, order: create(:order, shopify_store: store), aasm_state: "pending_process", number: 20)
    create(:package_item, package: pkg, sku: "A", quantity: 1)  # missing customs, no logistics/address
    get package_path(id: pkg.id)
    expect(response.body).to include(CGI.escapeHTML(I18n.t("packages.blockers.logistics")))
  end

  it "shows an order-cancelled warning on the list" do
    order = create(:order, shopify_store: store, financial_status: "paid", shopify_data: { "cancelled_at" => "2026-07-20T00:00:00Z" })
    create(:package, shopify_store: store, order: order, aasm_state: "pending_review", number: 21)
    get packages_path(state: "pending_review")
    expect(response.body).to include(CGI.escapeHTML(I18n.t("packages.order_cancelled")))
  end
end
```

- [ ] **Step 5: Run — FAIL, implement Steps 1-3, Run — PASS.**

- [ ] **Step 6: System spec** — an incomplete package's modal shows the blockers; a cancelled order shows the red warning on the list + modal.

- [ ] **Step 7: Commit**
```bash
bundle exec rspec spec/requests/packages_spec.rb spec/system/packages_spec.rb
git add app/views/packages config/locales spec
git commit -m "feat(packing): tab completeness checks, tracking blockers, and cancelled-order warning"
```

---

## Verification (before PR)
- [ ] `bundle exec rspec` green, coverage ≥95%.
- [ ] `bin/rubocop`, `bin/brakeman --no-pager`, `bin/bundler-audit` clean.
- [ ] Manual: open a package modal; review→process advances the step bar; edit address/customs → override flags set (re-sync preserves); assign logistics; blockers show what's missing; a cancelled order shows the warning; mobile viewport shows the full-screen modal with stacked sections.
- [ ] PR into `staging`.

## Self-Review notes
- **Design coverage:** modal (Turbo Frame + Stimulus chrome, responsive) (T3) ✓; step bar (T3) ✓; edit address+customs+logistics+note setting override flags where applicable (T5/T6/T7) ✓; review/hold/back state ops (T4) ✓; fine-grained review vs process gates (T1, enforced in T4-7) ✓; ready_for_tracking? + blockers + tab checks (T2, T8) ✓; cancelled-order warning (T2, T8) ✓; i18n all locales per task ✓; system specs for the modal/edits (T3-8) ✓.
- **Scope boundary:** no folding (拆分), no apply-tracking action/button (2C — only the readiness helper), no prev/next nav. Called out in Global Constraints.
- **Type consistency:** `package_review?`/`package_process?`, `ready_for_tracking?`/`tracking_blockers`/`order_cancelled?`/`address_complete?`/`logistics_assigned?`/`customs_complete?`, `transition_package_path(event:)`, `update_address`/`update_item`/`update_logistics`/`update_note`, `company_logistics_channels`, `dom_id(package, :address|:logistics|:note)` / `dom_id(item)` — consistent across tasks.
- **Known template gaps handled:** no existing turbo-frame modal → T3 builds it with a minimal Stimulus `modal` controller (mirrors order_picker open/close/backdrop). Row-edit reused as-is for customs. AASM bang events (not Ticket's string transition) used in T4 with `AASM::InvalidTransition` rescue.
