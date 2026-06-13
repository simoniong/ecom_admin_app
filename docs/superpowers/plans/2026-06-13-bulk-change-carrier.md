# Bulk Change Carrier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Change carrier" bulk action to the shipments hover bar that sets the correct 17Track carrier for selected shipments and re-tracks them.

**Architecture:** A searchable carrier picker (backed by a vendored 17Track carrier catalog) feeds a bulk POST that enqueues a background job; the job calls 17Track's `changecarrier` API (with a `register` fallback), persists the chosen carrier code, then re-tracks to refresh local data.

**Tech Stack:** Rails 8.1, RSpec + FactoryBot + WebMock, Hotwire/Stimulus, Tailwind, Solid Queue, HTTParty.

**Spec:** `docs/superpowers/specs/2026-06-13-bulk-change-carrier-design.md`

**Branch:** `feature/bulk-change-carrier` (already created).

---

## File Structure

- Create: `db/migrate/<ts>_add_carrier_code_to_fulfillments.rb` — schema column
- Create: `app/services/carrier_catalog.rb` — loads vendored carrier list
- Create: `config/data/17track_carriers.json` — vendored snapshot (generated)
- Create: `lib/tasks/tracking.rake` — `tracking:refresh_carriers` (append if exists)
- Create: `app/jobs/carrier_change_job.rb` — orchestrates change + re-track
- Create: `app/javascript/controllers/carrier_picker_controller.js` — modal + search
- Create: `app/views/shipments/_carrier_modal.html.erb` — modal markup
- Modify: `app/services/tracking_service.rb` — add `change_carrier`, extend `register`
- Modify: `app/controllers/shipments_controller.rb` — `carriers`, `bulk_change_carrier`
- Modify: `config/routes.rb` — two collection routes
- Modify: `app/javascript/controllers/shipment_bulk_controller.js` — `openCarrierModal`
- Modify: `app/views/shipments/index.html.erb` — hover-bar button + modal render
- Modify: `config/locales/en.yml`, `zh-CN.yml`, `zh-TW.yml` — strings
- Tests: `spec/models/fulfillment_spec.rb`, `spec/services/carrier_catalog_spec.rb`,
  `spec/services/tracking_service_spec.rb`, `spec/jobs/carrier_change_job_spec.rb`,
  `spec/requests/shipments_spec.rb`, `spec/system/shipments_carrier_spec.rb`
- Test fixture: `spec/fixtures/files/17track_carriers.json`

Run all commands with the Ruby toolchain on PATH:
`export PATH="/home/simon/.rubies/ruby-3.4.7/bin:$PATH"`

---

### Task 1: Migration — add `carrier_code` to fulfillments

**Files:**
- Create: `db/migrate/<ts>_add_carrier_code_to_fulfillments.rb`
- Modify: `db/schema.rb` (via migrate)
- Test: `spec/models/fulfillment_spec.rb`

- [ ] **Step 1: Generate the migration**

Run: `bin/rails g migration AddCarrierCodeToFulfillments carrier_code:integer`

- [ ] **Step 2: Verify migration contents**

Open the generated file; it must read exactly:

```ruby
class AddCarrierCodeToFulfillments < ActiveRecord::Migration[8.1]
  def change
    add_column :fulfillments, :carrier_code, :integer
  end
end
```

- [ ] **Step 3: Migrate (dev + test)**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: `schema.rb` now has `t.integer "carrier_code"` on `fulfillments`.

- [ ] **Step 4: Write a model spec asserting the attribute exists**

Add to `spec/models/fulfillment_spec.rb` (inside the top-level describe):

```ruby
  describe "carrier_code" do
    it "persists a 17Track carrier code" do
      fulfillment = create(:fulfillment, tracking_number: "CC1", carrier_code: 21051)
      expect(fulfillment.reload.carrier_code).to eq(21051)
    end

    it "defaults to nil" do
      expect(create(:fulfillment, tracking_number: "CC2").carrier_code).to be_nil
    end
  end
```

- [ ] **Step 5: Run the spec**

Run: `bundle exec rspec spec/models/fulfillment_spec.rb -e carrier_code`
Expected: PASS (2 examples). SimpleCov exit-2 on single-file runs is expected.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add carrier_code column to fulfillments"
```

---

### Task 2: CarrierCatalog service + vendored snapshot + refresh task

**Files:**
- Create: `app/services/carrier_catalog.rb`
- Create: `config/data/17track_carriers.json`
- Create: `lib/tasks/tracking.rake`
- Create: `spec/fixtures/files/17track_carriers.json`
- Test: `spec/services/carrier_catalog_spec.rb`

- [ ] **Step 1: Create the test fixture**

Create `spec/fixtures/files/17track_carriers.json`:

```json
[
  { "code": 21051, "name": "USPS", "country": "US" },
  { "code": 3011, "name": "China Post", "country": "CN" },
  { "code": 3013, "name": "China EMS", "country": "CN" }
]
```

- [ ] **Step 2: Write the failing spec**

Create `spec/services/carrier_catalog_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe CarrierCatalog do
  let(:path) { Rails.root.join("spec/fixtures/files/17track_carriers.json") }
  subject(:catalog) { described_class.new(path: path) }

  describe "#all" do
    it "returns the parsed carrier entries" do
      expect(catalog.all).to include({ "code" => 21051, "name" => "USPS", "country" => "US" })
      expect(catalog.all.size).to eq(3)
    end
  end

  describe "#valid?" do
    it "is true for a known code (int or string)" do
      expect(catalog.valid?(21051)).to be(true)
      expect(catalog.valid?("3011")).to be(true)
    end

    it "is false for an unknown code" do
      expect(catalog.valid?(99999)).to be(false)
    end
  end

  describe "#name_for" do
    it "returns the carrier name" do
      expect(catalog.name_for(3013)).to eq("China EMS")
    end

    it "returns nil for unknown" do
      expect(catalog.name_for(1)).to be_nil
    end
  end

  describe "missing file" do
    it "returns an empty list instead of raising" do
      empty = described_class.new(path: Rails.root.join("tmp/does_not_exist.json"))
      expect(empty.all).to eq([])
      expect(empty.valid?(21051)).to be(false)
    end
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `bundle exec rspec spec/services/carrier_catalog_spec.rb`
Expected: FAIL with `uninitialized constant CarrierCatalog`.

- [ ] **Step 4: Implement CarrierCatalog**

Create `app/services/carrier_catalog.rb`:

```ruby
class CarrierCatalog
  DEFAULT_PATH = Rails.root.join("config/data/17track_carriers.json")

  def self.default
    @default ||= new
  end

  def self.reset!
    @default = nil
  end

  def initialize(path: DEFAULT_PATH)
    @path = path
  end

  def all
    @all ||= load_entries
  end

  def valid?(code)
    index.key?(code.to_i)
  end

  def name_for(code)
    index[code.to_i]
  end

  private

  def index
    @index ||= all.each_with_object({}) { |c, h| h[c["code"].to_i] = c["name"] }
  end

  def load_entries
    return [] unless File.exist?(@path)

    JSON.parse(File.read(@path))
  rescue JSON::ParserError
    []
  end
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bundle exec rspec spec/services/carrier_catalog_spec.rb`
Expected: PASS (6 examples).

- [ ] **Step 6: Create the refresh rake task**

Create `lib/tasks/tracking.rake`:

```ruby
namespace :tracking do
  desc "Refresh the vendored 17Track carrier catalog snapshot"
  task refresh_carriers: :environment do
    url = "https://res.17track.net/asset/carrier/info/apicarrier.all.json"
    response = HTTParty.get(url, headers: { "User-Agent" => "ecom_admin_app" })
    raise "Carrier fetch failed (#{response.code})" unless response.success?

    entries = JSON.parse(response.body).map do |c|
      { "code" => c["key"], "name" => c["_name"], "country" => c["_country_iso"] }
    end.select { |c| c["code"] && c["name"] }.sort_by { |c| c["name"].to_s }

    path = CarrierCatalog::DEFAULT_PATH
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(entries))
    puts "Wrote #{entries.size} carriers to #{path}"
  end
end
```

- [ ] **Step 7: Generate the initial vendored snapshot**

Run: `bin/rails tracking:refresh_carriers`
Expected: prints "Wrote <N> carriers" with N in the thousands; creates `config/data/17track_carriers.json`.

If the fetch returns 403/blocked from this environment: copy the test fixture as a minimal seed —
`mkdir -p config/data && cp spec/fixtures/files/17track_carriers.json config/data/17track_carriers.json` —
and note in the commit that the full snapshot must be generated from a host that can reach 17Track's asset CDN. Do not block the feature on the full list.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: add CarrierCatalog and 17Track carrier snapshot + refresh task"
```

---

### Task 3: TrackingService — `change_carrier` + extend `register`

**Files:**
- Modify: `app/services/tracking_service.rb`
- Test: `spec/services/tracking_service_spec.rb`

- [ ] **Step 1: Write the failing specs**

Add to `spec/services/tracking_service_spec.rb` (inside the top-level describe):

```ruby
  describe "#change_carrier" do
    let(:service) { described_class.new(api_key: "KEY") }

    it "posts number + carrier_new and returns accepted/rejected" do
      stub_request(:post, TrackingService::CHANGECARRIER_URL)
        .with(body: [ { number: "RR1", carrier_new: 3011 } ].to_json)
        .to_return(status: 200, body: {
          data: { accepted: [ { number: "RR1" } ], rejected: [] }
        }.to_json)

      result = service.change_carrier([ "RR1" ], carrier_new: 3011)
      expect(result).to eq(accepted: [ "RR1" ], rejected: [])
    end

    it "parses rejected entries with their error code" do
      stub_request(:post, TrackingService::CHANGECARRIER_URL)
        .to_return(status: 200, body: {
          data: { accepted: [], rejected: [ { number: "BAD", error: { code: -18019902 } } ] }
        }.to_json)

      result = service.change_carrier([ "BAD" ], carrier_new: 3011)
      expect(result[:rejected]).to eq([ { number: "BAD", code: -18019902 } ])
    end

    it "batches in groups of 40" do
      numbers = (1..45).map { |i| "N#{i}" }
      stub = stub_request(:post, TrackingService::CHANGECARRIER_URL)
        .to_return(status: 200, body: { data: { accepted: [], rejected: [] } }.to_json)

      service.change_carrier(numbers, carrier_new: 3011)
      expect(stub).to have_been_requested.twice
    end
  end

  describe "#register with a carrier" do
    let(:service) { described_class.new(api_key: "KEY") }

    it "includes carrier and auto_detection=false when carrier given" do
      stub = stub_request(:post, TrackingService::REGISTER_URL)
        .with(body: [ { number: "T1", carrier: 3011, auto_detection: false } ].to_json)
        .to_return(status: 200, body: { data: { accepted: [ { number: "T1" } ] } }.to_json)

      service.register([ "T1" ], carrier: 3011)
      expect(stub).to have_been_requested
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `bundle exec rspec spec/services/tracking_service_spec.rb -e change_carrier`
Expected: FAIL with `uninitialized constant ...CHANGECARRIER_URL` / no method.

- [ ] **Step 3: Add the constant and method, extend register**

In `app/services/tracking_service.rb`, add the URL constant under the existing ones:

```ruby
  CHANGECARRIER_URL = "#{BASE_URL}/changecarrier"
  CARRIER_BATCH_SIZE = 40
```

Replace the existing `register` method with:

```ruby
  def register(tracking_numbers, carrier: nil, auto_detection: true)
    return [] if tracking_numbers.blank?

    body = tracking_numbers.map do |tn|
      entry = { number: tn }
      if carrier
        entry[:carrier] = carrier
        entry[:auto_detection] = auto_detection
      end
      entry
    end

    response = HTTParty.post(REGISTER_URL, headers: headers, body: body.to_json)
    raise "17Track register error (#{response.code}): #{response.body}" unless response.success?

    data = response.parsed_response
    data.dig("data", "accepted") || []
  end
```

Add the new method (after `register`):

```ruby
  def change_carrier(tracking_numbers, carrier_new:)
    accepted = []
    rejected = []

    Array(tracking_numbers).reject(&:blank?).each_slice(CARRIER_BATCH_SIZE) do |batch|
      body = batch.map { |tn| { number: tn, carrier_new: carrier_new } }
      response = HTTParty.post(CHANGECARRIER_URL, headers: headers, body: body.to_json)
      raise "17Track changecarrier error (#{response.code}): #{response.body}" unless response.success?

      data = response.parsed_response["data"] || {}
      (data["accepted"] || []).each { |item| accepted << item["number"] }
      (data["rejected"] || []).each { |item| rejected << { number: item["number"], code: item.dig("error", "code") } }
    end

    { accepted: accepted, rejected: rejected }
  end
```

- [ ] **Step 4: Run to verify they pass**

Run: `bundle exec rspec spec/services/tracking_service_spec.rb`
Expected: PASS (all existing + 4 new examples).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: TrackingService change_carrier + carrier-aware register"
```

---

### Task 4: CarrierChangeJob

**Files:**
- Create: `app/jobs/carrier_change_job.rb`
- Test: `spec/jobs/carrier_change_job_spec.rb`

- [ ] **Step 1: Write the failing spec**

Create `spec/jobs/carrier_change_job_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe CarrierChangeJob, type: :job do
  let(:company) do
    create(:company, tracking_enabled: true, tracking_api_key: ("A" * 32),
           tracking_mode: "new_only", tracking_starts_at: Time.current)
  end
  let(:store) { create(:shopify_store, company: company) }
  let(:order) { create(:order, shopify_store: store) }
  let!(:fulfillment) { create(:fulfillment, order: order, tracking_number: "RR1", tracking_status: "InTransit") }

  let(:service) { instance_double(TrackingService) }

  before do
    allow(TrackingService).to receive(:new).with(api_key: "A" * 32).and_return(service)
    allow(service).to receive(:change_carrier).and_return(accepted: [ "RR1" ], rejected: [])
    allow(service).to receive(:register)
    allow(service).to receive(:track).and_return([
      { tracking_number: "RR1", status: "InTransit", sub_status: "InTransit_Other",
        origin_carrier: "China Post", destination_carrier: nil, origin_country: "CN",
        destination_country: "US", transit_days: 5, last_event: "Accepted",
        last_event_time: "2026-06-13T08:00:00+08:00", events: [] }
    ])
  end

  it "calls change_carrier with the selected numbers and code" do
    described_class.perform_now(company.id, [ fulfillment.id ], 3011)
    expect(service).to have_received(:change_carrier).with([ "RR1" ], carrier_new: 3011)
  end

  it "persists carrier_code on the fulfillment" do
    described_class.perform_now(company.id, [ fulfillment.id ], 3011)
    expect(fulfillment.reload.carrier_code).to eq(3011)
  end

  it "re-tracks and applies the result" do
    described_class.perform_now(company.id, [ fulfillment.id ], 3011)
    expect(fulfillment.reload.origin_carrier).to eq("China Post")
    expect(service).to have_received(:track).with([ "RR1" ])
  end

  it "falls back to register for rejected numbers" do
    allow(service).to receive(:change_carrier)
      .and_return(accepted: [], rejected: [ { number: "RR1", code: -18019902 } ])

    described_class.perform_now(company.id, [ fulfillment.id ], 3011)
    expect(service).to have_received(:register).with([ "RR1" ], carrier: 3011, auto_detection: false)
  end

  it "does nothing when tracking disabled" do
    disabled = create(:company)
    expect(TrackingService).not_to receive(:new)
    described_class.perform_now(disabled.id, [ fulfillment.id ], 3011)
  end

  it "ignores fulfillments outside the company's stores" do
    other_store = create(:shopify_store, company: create(:company))
    other_f = create(:fulfillment, order: create(:order, shopify_store: other_store), tracking_number: "X9")
    described_class.perform_now(company.id, [ other_f.id ], 3011)
    expect(service).to have_received(:change_carrier).with([ "RR1" ], carrier_new: 3011)
  end
end
```

Note: the cross-store example passes only `other_f.id`, but `fulfillment` (RR1) belongs to the company; assert RR1 is what gets processed and the out-of-scope id is excluded. Adjust to pass both ids:
replace `[ other_f.id ]` with `[ fulfillment.id, other_f.id ]`.

- [ ] **Step 2: Run to verify it fails**

Run: `bundle exec rspec spec/jobs/carrier_change_job_spec.rb`
Expected: FAIL with `uninitialized constant CarrierChangeJob`.

- [ ] **Step 3: Implement the job**

Create `app/jobs/carrier_change_job.rb`:

```ruby
class CarrierChangeJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  BATCH_SIZE = 40

  def perform(company_id, fulfillment_ids, carrier_code)
    company = Company.find_by(id: company_id)
    return unless company&.tracking_enabled?
    return if company.tracking_api_key.blank?

    fulfillments = scoped_fulfillments(company, fulfillment_ids)
    return if fulfillments.empty?

    service = TrackingService.new(api_key: company.tracking_api_key)
    by_number = fulfillments.index_by(&:tracking_number)

    by_number.keys.each_slice(BATCH_SIZE) do |numbers|
      result = service.change_carrier(numbers, carrier_new: carrier_code)

      if result[:rejected].any?
        retry_numbers = result[:rejected].map { |r| r[:number] }
        Rails.logger.warn("[CarrierChange] changecarrier rejected #{retry_numbers.inspect}; registering with carrier #{carrier_code}")
        service.register(retry_numbers, carrier: carrier_code, auto_detection: false)
      end

      ids = numbers.map { |n| by_number[n]&.id }.compact
      Fulfillment.where(id: ids).update_all(carrier_code: carrier_code)

      service.track(numbers).each do |res|
        by_number[res[:tracking_number]]&.update_from_tracking_result(res)
      end
    end
  end

  private

  def scoped_fulfillments(company, ids)
    store_ids = company.shopify_stores.pluck(:id)
    Fulfillment.with_tracking
               .where(id: ids)
               .joins(:order)
               .where(orders: { shopify_store_id: store_ids })
               .to_a
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bundle exec rspec spec/jobs/carrier_change_job_spec.rb`
Expected: PASS (7 examples).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: CarrierChangeJob — change carrier, register fallback, re-track"
```

---

### Task 5: Controller actions + routes

**Files:**
- Modify: `config/routes.rb:89-101`
- Modify: `app/controllers/shipments_controller.rb`
- Test: `spec/requests/shipments_spec.rb`

- [ ] **Step 1: Add routes**

In `config/routes.rb`, inside the `resources :shipments` block (after `get :available_tags, on: :collection`):

```ruby
      post :bulk_change_carrier, on: :collection
      get :carriers, on: :collection
```

- [ ] **Step 2: Write failing request specs**

Add to `spec/requests/shipments_spec.rb` (inside `describe "GET /shipments"`'s parent describe, alongside the bulk specs):

```ruby
  describe "carrier actions" do
    it "returns the carrier catalog as JSON" do
      get carriers_shipments_path
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")
    end

    it "enqueues CarrierChangeJob for scoped shipments" do
      order = create(:order, customer: customer, shopify_store: store)
      f = create(:fulfillment, order: order, tracking_number: "CARRIER_T1", tracking_status: "InTransit")

      expect {
        post bulk_change_carrier_shipments_path, params: { ids: [ f.id ], carrier_code: 21051 }
      }.to have_enqueued_job(CarrierChangeJob).with(kind_of(String), [ f.id ], 21051)

      expect(response).to redirect_to(shipments_path(archived: nil))
    end

    it "rejects an invalid carrier code without enqueuing" do
      order = create(:order, customer: customer, shopify_store: store)
      f = create(:fulfillment, order: order, tracking_number: "CARRIER_T2", tracking_status: "InTransit")

      expect {
        post bulk_change_carrier_shipments_path, params: { ids: [ f.id ], carrier_code: 99999999 }
      }.not_to have_enqueued_job(CarrierChangeJob)

      expect(flash[:alert]).to be_present
    end
  end
```

This spec relies on the real catalog (`CarrierCatalog.default`). To keep it deterministic, point the default at the fixture in a `before`:

```ruby
  describe "carrier actions" do
    before do
      allow(CarrierCatalog).to receive(:default)
        .and_return(CarrierCatalog.new(path: Rails.root.join("spec/fixtures/files/17track_carriers.json")))
    end
    # ... examples above ...
  end
```

(21051/USPS is valid in the fixture; 99999999 is not.)

- [ ] **Step 3: Run to verify they fail**

Run: `bundle exec rspec spec/requests/shipments_spec.rb -e "carrier actions"`
Expected: FAIL (`carriers_shipments_path` undefined or 404).

- [ ] **Step 4: Implement the controller actions**

In `app/controllers/shipments_controller.rb`, add as public actions (next to `bulk_export` / `available_tags`):

```ruby
  def carriers
    render json: CarrierCatalog.default.all
  end

  def bulk_change_carrier
    ids = sanitize_ids(params[:ids])
    code = params[:carrier_code].to_i

    unless code.positive? && CarrierCatalog.default.valid?(code)
      return redirect_to shipments_path(archived: params[:archived]), alert: t("shipments.carrier.invalid")
    end

    fulfillment_ids = scoped_fulfillments(ids).with_tracking.pluck(:id)
    CarrierChangeJob.perform_later(current_company.id, fulfillment_ids, code) if fulfillment_ids.any?

    redirect_to shipments_path(archived: params[:archived]),
                notice: t("shipments.carrier.queued", count: fulfillment_ids.size)
  end
```

- [ ] **Step 5: Add locale strings (needed for the controller flashes)**

In each of `config/locales/en.yml`, `zh-CN.yml`, `zh-TW.yml`, under `shipments:` add a `carrier:` block. English:

```yaml
    carrier:
      invalid: "Please select a valid carrier."
      queued:
        one: "Queued carrier change for %{count} shipment."
        other: "Queued carrier change for %{count} shipments."
      button: "Change carrier"
      modal_title: "Change carrier"
      search_placeholder: "Search carriers…"
      confirm: "Change carrier"
      cancel: "Cancel"
      no_results: "No carriers found"
```

zh-CN:

```yaml
    carrier:
      invalid: "请选择有效的承运商。"
      queued:
        one: "已为 %{count} 个货件排入承运商变更。"
        other: "已为 %{count} 个货件排入承运商变更。"
      button: "更改承运商"
      modal_title: "更改承运商"
      search_placeholder: "搜索承运商…"
      confirm: "更改承运商"
      cancel: "取消"
      no_results: "未找到承运商"
```

zh-TW:

```yaml
    carrier:
      invalid: "請選擇有效的承運商。"
      queued:
        one: "已為 %{count} 個貨件排入承運商變更。"
        other: "已為 %{count} 個貨件排入承運商變更。"
      button: "更改承運商"
      modal_title: "更改承運商"
      search_placeholder: "搜尋承運商…"
      confirm: "更改承運商"
      cancel: "取消"
      no_results: "找不到承運商"
```

- [ ] **Step 6: Run to verify they pass**

Run: `bundle exec rspec spec/requests/shipments_spec.rb -e "carrier actions"`
Expected: PASS (3 examples).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: carriers JSON + bulk_change_carrier controller actions + locales"
```

---

### Task 6: Frontend — carrier picker modal + hover-bar button

**Files:**
- Create: `app/javascript/controllers/carrier_picker_controller.js`
- Create: `app/views/shipments/_carrier_modal.html.erb`
- Modify: `app/javascript/controllers/shipment_bulk_controller.js`
- Modify: `app/views/shipments/index.html.erb`

- [ ] **Step 1: Create the carrier picker Stimulus controller**

Create `app/javascript/controllers/carrier_picker_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// Mirrors the shipment-tags modal contract: exposes `formTarget`,
// `idsContainerTarget`, and `open(event)` for shipment-bulk to drive.
export default class extends Controller {
  static targets = ["modal", "form", "idsContainer", "search", "results", "code", "confirm"]
  static values = { url: String, noResults: String }

  connect() {
    this.carriers = null
  }

  async open() {
    this.modalTarget.classList.remove("hidden")
    this.resetSelection()
    if (!this.carriers) await this.loadCarriers()
    this.render(this.carriers.slice(0, 50))
    this.searchTarget.focus()
  }

  close() {
    this.modalTarget.classList.add("hidden")
  }

  async loadCarriers() {
    const res = await fetch(this.urlValue, { headers: { Accept: "application/json" } })
    this.carriers = res.ok ? await res.json() : []
  }

  filter() {
    const q = this.searchTarget.value.trim().toLowerCase()
    if (!q) return this.render(this.carriers.slice(0, 50))
    const matches = this.carriers.filter(c =>
      c.name.toLowerCase().includes(q) || String(c.code).includes(q)
    ).slice(0, 50)
    this.render(matches)
  }

  render(list) {
    if (!list.length) {
      this.resultsTarget.innerHTML = `<p class="px-3 py-2 text-sm text-gray-500">${this.noResultsValue}</p>`
      return
    }
    this.resultsTarget.innerHTML = list.map(c => `
      <button type="button" data-action="click->carrier-picker#select"
              data-code="${c.code}" data-name="${c.name}"
              class="flex items-center justify-between w-full px-3 py-2 text-sm text-left hover:bg-gray-50">
        <span class="text-gray-700">${c.name}</span>
        <span class="text-xs text-gray-400">${c.country || ""} · ${c.code}</span>
      </button>`).join("")
  }

  select(event) {
    const { code, name } = event.currentTarget.dataset
    this.codeTarget.value = code
    this.searchTarget.value = name
    this.confirmTarget.disabled = false
    this.resultsTarget.innerHTML = ""
  }

  resetSelection() {
    this.codeTarget.value = ""
    this.searchTarget.value = ""
    this.confirmTarget.disabled = true
    this.resultsTarget.innerHTML = ""
  }
}
```

- [ ] **Step 2: Create the carrier modal partial**

Create `app/views/shipments/_carrier_modal.html.erb`:

```erb
<div data-controller="carrier-picker"
     data-carrier-picker-url-value="<%= carriers_shipments_path(format: :json) %>"
     data-carrier-picker-no-results-value="<%= t("shipments.carrier.no_results") %>">
  <div data-carrier-picker-target="modal" class="hidden fixed inset-0 z-50 flex items-center justify-center" role="dialog" aria-modal="true">
    <div class="fixed inset-0 bg-black/40" data-action="click->carrier-picker#close"></div>
    <div class="relative bg-white rounded-xl shadow-2xl w-full max-w-lg mx-4 flex flex-col">
      <div class="flex items-center justify-between px-6 pt-5 pb-3">
        <h2 class="text-lg font-semibold text-gray-900"><%= t("shipments.carrier.modal_title") %></h2>
        <button type="button" data-action="click->carrier-picker#close" class="text-gray-400 hover:text-gray-600" aria-label="<%= t("shipments.carrier.cancel") %>">
          <svg class="w-5 h-5" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" d="M6 18 18 6M6 6l12 12" />
          </svg>
        </button>
      </div>

      <%= form_with url: bulk_change_carrier_shipments_path(archived: @archived ? "true" : nil), method: :post, data: { carrier_picker_target: "form" } do |f| %>
        <div class="px-6 pb-2">
          <input type="text" data-carrier-picker-target="search"
                 data-action="input->carrier-picker#filter"
                 placeholder="<%= t("shipments.carrier.search_placeholder") %>"
                 class="block w-full px-3 py-2 rounded-md border border-gray-300 shadow-sm text-sm focus:border-blue-500 focus:ring-blue-500">
          <div data-carrier-picker-target="results" class="mt-2 max-h-64 overflow-y-auto border border-gray-100 rounded-md"></div>
          <input type="hidden" name="carrier_code" data-carrier-picker-target="code">
          <div data-carrier-picker-target="idsContainer"></div>
        </div>
        <div class="flex items-center justify-end gap-2 px-6 py-4 border-t border-gray-100">
          <button type="button" data-action="click->carrier-picker#close" class="px-4 py-2 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50"><%= t("shipments.carrier.cancel") %></button>
          <%= f.submit t("shipments.carrier.confirm"), data: { carrier_picker_target: "confirm" }, disabled: true,
                class: "px-4 py-2 text-sm font-medium text-white bg-gray-900 rounded-md hover:bg-gray-800 disabled:opacity-50 cursor-pointer" %>
        </div>
      <% end %>
    </div>
  </div>
</div>
```

- [ ] **Step 3: Add `openCarrierModal` to shipment_bulk_controller.js**

In `app/javascript/controllers/shipment_bulk_controller.js`, add this method (after `openTagModal`):

```javascript
  openCarrierModal(event) {
    const picker = this.application.getControllerForElementAndIdentifier(
      document.querySelector("[data-controller='carrier-picker']"),
      "carrier-picker"
    )
    if (!picker) return

    picker.idsContainerTarget.innerHTML = ""
    this.selectedData().forEach(d => {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "ids[]"
      input.value = d.id
      picker.idsContainerTarget.appendChild(input)
    })

    picker.open(event)
  }
```

- [ ] **Step 4: Add the hover-bar button + render the modal**

In `app/views/shipments/index.html.erb`, add a button in the hover bar immediately before the `<div class="w-px h-5 bg-gray-200"></div>` that precedes the archive button (around line 672):

```erb
        <button type="button" data-action="click->shipment-bulk#openCarrierModal"
                class="inline-flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium text-gray-700 bg-gray-50 border border-gray-200 rounded-lg hover:bg-gray-100 transition-colors">
          <svg class="w-4 h-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" d="M8.25 18.75a1.5 1.5 0 0 1-3 0m3 0a1.5 1.5 0 0 0-3 0m3 0h6m-9 0H3.375a1.125 1.125 0 0 1-1.125-1.125V14.25m17.25 4.5a1.5 1.5 0 0 1-3 0m3 0a1.5 1.5 0 0 0-3 0m3 0h1.125c.621 0 1.129-.504 1.09-1.124a17.902 17.902 0 0 0-3.213-9.193 2.056 2.056 0 0 0-1.58-.86H14.25M16.5 18.75h-6.375m0-11.25h4.5m-4.5 0V5.25A2.25 2.25 0 0 0 7.5 3h-3A2.25 2.25 0 0 0 2.25 5.25v9.75" />
          </svg>
          <%= t("shipments.carrier.button") %>
        </button>
```

Then add the modal render after the existing tag modal block (after the `</div>` that closes the `data-controller="shipment-tags"` wrapper, around line 707):

```erb
    <%# Carrier modal %>
    <%= render "shipments/carrier_modal" %>
```

- [ ] **Step 5: Manual smoke check (build assets, no errors)**

Run: `bin/rails assets:precompile 2>&1 | tail -5` (or rely on importmap — verify the new controller path resolves)
Expected: no Stimulus/asset errors. (Importmap auto-loads `app/javascript/controllers/*`.)

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: carrier change hover-bar button + searchable picker modal"
```

---

### Task 7: System spec + full suite

**Files:**
- Create: `spec/system/shipments_carrier_spec.rb`
- Test: full run

- [ ] **Step 1: Write the system spec**

Create `spec/system/shipments_carrier_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Shipments carrier change", type: :system do
  let!(:user) { create(:user) }

  before do
    membership = user.membership_for(user.companies.first)
    membership.update!(permissions: membership.permissions + [ "shipments" ])
    company = user.companies.first
    company.update!(tracking_enabled: true, tracking_api_key: "A" * 32,
                    tracking_mode: "new_only", tracking_starts_at: Time.current)
    store = create(:shopify_store, company: company)
    order = create(:order, shopify_store: store)
    create(:fulfillment, order: order, tracking_number: "SYS_CARRIER_1", tracking_status: "InTransit")

    allow(CarrierCatalog).to receive(:default)
      .and_return(CarrierCatalog.new(path: Rails.root.join("spec/fixtures/files/17track_carriers.json")))
  end

  it "changes carrier for selected shipments via the hover bar" do
    sign_in_as(user)
    visit shipments_path

    find("[data-shipment-bulk-target='selectAll']").check
    click_button I18n.t("shipments.carrier.button")

    fill_in placeholder: I18n.t("shipments.carrier.search_placeholder"), with: "China Post"
    click_button "China Post"
    click_button I18n.t("shipments.carrier.confirm")

    expect(page).to have_text(I18n.t("shipments.carrier.queued", count: 1))
  end
end
```

Note: the `carriers` endpoint serves the stubbed `CarrierCatalog.default`, so "China Post" (code 3011) is searchable.

- [ ] **Step 2: Run the targeted specs (system needs Chrome — will run in CI)**

Run: `bundle exec rspec spec/services/carrier_catalog_spec.rb spec/services/tracking_service_spec.rb spec/jobs/carrier_change_job_spec.rb spec/requests/shipments_spec.rb spec/models/fulfillment_spec.rb`
Expected: all PASS. (System spec runs in CI where Chrome is available.)

- [ ] **Step 3: RuboCop + Brakeman**

Run: `bin/rubocop app/ lib/ spec/ && bin/brakeman --no-pager -q`
Expected: no offenses; no new security warnings.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "test: system spec for bulk carrier change"
```

- [ ] **Step 5: Push + open PR to staging**

```bash
git push -u origin feature/bulk-change-carrier
gh pr create --base staging --title "feat: bulk change carrier for shipments" --body "Implements docs/superpowers/specs/2026-06-13-bulk-change-carrier-design.md"
```

---

## Self-Review

**Spec coverage:**
- Data model `carrier_code` → Task 1 ✓
- CarrierCatalog + vendored snapshot + refresh task + endpoint → Task 2, Task 5 (endpoint) ✓
- UI hover-bar button + searchable modal + Stimulus → Task 6 ✓
- Controller `bulk_change_carrier` + validation + scoping + flash → Task 5 ✓
- `TrackingService#change_carrier` + register extension → Task 3 ✓
- `CarrierChangeJob` change + register fallback + re-track + persist → Task 4 ✓
- Flash + next-refresh feedback → Task 5 (async redirect) ✓
- Error handling (invalid code, rejected→fallback, scoping) → Task 4, Task 5 ✓
- Tests: service/job/request/catalog/system/locales → Tasks 2–7 ✓

**Placeholder scan:** none — all steps carry concrete code/commands.

**Type consistency:** `change_carrier(numbers, carrier_new:)` returns `{accepted:, rejected:[{number:, code:}]}` — consistent across Task 3 (impl), Task 4 (job consumes `r[:number]`). `register(numbers, carrier:, auto_detection:)` consistent across Task 3 + Task 4. `CarrierCatalog.default` / `.valid?` / `.all` / `.name_for` consistent across Tasks 2, 5. `carrier-picker` targets (`form`, `idsContainer`, `open`) match the `openCarrierModal` consumer in Task 6.
