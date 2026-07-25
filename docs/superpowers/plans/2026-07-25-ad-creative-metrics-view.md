# Ad Creative Metrics View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a creative-level (video/image asset) metrics view for Meta ads showing completion rates, link CTR, D1/D3/D5 cold-start ROAS, and lifetime ROAS.

**Architecture:** Meta's `video_asset` breakdown cannot carry video completion metrics, so ad-level daily metrics are synced into `ad_unit_daily_metrics` and rolled up to `ad_creatives` locally via an `ad_units` mapping table. A contiguous per-account coverage interval (`creative_synced_from_date` / `_through_date`) is the single source of truth for whether a metric window is computable.

**Tech Stack:** Rails 8.1, PostgreSQL (UUID PKs), Koala (Meta Graph API), Solid Queue, RSpec + FactoryBot, Tailwind, Hotwire.

**Spec:** `docs/superpowers/specs/2026-07-25-ad-creative-metrics-view-design.md` — read §2–§7 before starting. Section references below (§4.0, §5.6, §6.3 …) point at that file.

## Global Constraints

- All table primary keys are UUID: `create_table :x, id: :uuid`, FKs `type: :uuid`.
- Never commit to `main` or `staging`. Work happens on `feature/ad-creative-metrics-view`.
- RSpec + FactoryBot only, no fixtures. Do not mock the database. External Meta API is doubled with `instance_double(Koala::Facebook::API)` — see `spec/services/meta_ads_service_spec.rb` for the established pattern.
- 95%+ coverage required.
- RuboCop Omakase. Run `bin/rubocop -a` before each commit.
- Ruby toolchain: prepend `/home/simon/.rubies/ruby-3.4.7/bin` to `PATH` for all `bin/rails` / `bundle exec rspec` invocations. A SimpleCov exit code 2 on a single-file spec run is expected and is not a failure.
- Routes live inside a `scope "(:locale)"`. Path helpers need explicit keyword args (`ad_creatives_path(id: x)`), never a positional record.
- **All date arithmetic uses the ad account timezone** (`ActiveSupport::TimeZone[ad_account.timezone].today`), never `Date.current` / `days.ago.to_date` (§2.4).
- Meta conversion action types, verbatim: `offsite_conversion.fb_pixel_add_to_cart`, `offsite_conversion.fb_pixel_initiate_checkout`, `offsite_conversion.fb_pixel_purchase`.
- **The coverage invariant (§5.6):** every `ad_unit_daily_metrics.date` must fall inside the contiguous `[creative_synced_from_date, creative_synced_through_date]` interval. No metric rows may exist while either bound is null, except inside the mode A first-segment transaction.
- Backfill depth N = 90 days. Mode C (backward deepening) is explicitly **out of scope**.

---

## Spec Gap Resolved In This Plan

The spec (§5.6) says manual backfill "不受退避限制" (bypasses backoff) but also that it "仍走同一個原子 UPDATE" (uses the same atomic claim). Those conflict: if `attempts` is high, the backoff timestamp is up to 24h out and the shared due-check would block the manual click it is supposed to let through.

**Resolution used by this plan:** the claim predicate differs by caller.

- Automatic: claim when `next_attempt_at IS NULL OR next_attempt_at <= NOW()`.
- Manual: claim when `next_attempt_at IS NULL OR next_attempt_at <= NOW() OR attempts > 0`.

`attempts > 0` means the timestamp was set by failure backoff, so manual bypasses it. `attempts == 0` means the timestamp came from a successful sync or a previous manual click, so the 1-hour rapid-click guard still applies. No extra column needed. This is implemented in Task 5.

---

## File Structure

**Migrations** (`db/migrate/`)
- `create_ad_creatives`, `create_ad_units`, `create_ad_unit_daily_metrics`, `add_creative_sync_fields_to_ad_accounts`

**Models** (`app/models/`)
- `ad_creative.rb` — aggregation unit; `anchor_state`, `batch_aggregated_metrics`, `CreativeMetrics`
- `ad_unit.rb` — Meta ad ↔ creative mapping
- `ad_unit_daily_metric.rb` — daily rows
- `ad_account.rb` (modify) — associations + `claim_backfill_slot!` + `release_backfill_slot!` + `today_in_zone`

**Services** (`app/services/`)
- `meta_ads_service.rb` (modify) — `sync_ad_units`, `fetch_ad_insights`, `sync_creative_assets`, `extract_video_metric`, `resolve_asset`
- `ad_creative_backfill_service.rb` — segmentation, coverage advancement, transactions

**Jobs** (`app/jobs/`)
- `backfill_ad_creatives_job.rb`, `sync_ad_creatives_job.rb`

**Controller / views / config**
- `app/controllers/ad_creatives_controller.rb`
- `app/views/ad_creatives/index.html.erb`
- `config/routes.rb`, `config/recurring.yml`, `config/locales/{en,zh-TW,zh-CN}.yml`
- `app/models/membership.rb`, `app/controllers/admin_controller.rb`, `app/views/shared/_sidebar.html.erb`

**Factories** (`spec/factories/`) — `ad_creatives.rb`, `ad_units.rb`, `ad_unit_daily_metrics.rb`

---

### Task 1: Schema, models, factories

**Files:**
- Create: `db/migrate/<ts>_create_ad_creatives.rb`, `db/migrate/<ts>_create_ad_units.rb`, `db/migrate/<ts>_create_ad_unit_daily_metrics.rb`, `db/migrate/<ts>_add_creative_sync_fields_to_ad_accounts.rb`
- Create: `app/models/ad_creative.rb`, `app/models/ad_unit.rb`, `app/models/ad_unit_daily_metric.rb`
- Create: `spec/factories/ad_creatives.rb`, `spec/factories/ad_units.rb`, `spec/factories/ad_unit_daily_metrics.rb`
- Modify: `app/models/ad_account.rb`
- Test: `spec/models/ad_creative_spec.rb`, `spec/models/ad_unit_spec.rb`, `spec/models/ad_unit_daily_metric_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `AdCreative` (`ad_account_id`, `asset_type`, `asset_id`, `name`, `thumbnail_url`, `duration_seconds`, `first_spend_date`), `AdUnit` (`ad_account_id`, `ad_creative_id`, `ad_campaign_id`, `ad_id`, `ad_name`, `adset_id`, `status`, `multi_asset`), `AdUnitDailyMetric` (metric columns per §4.3), `AdAccount#creative_synced_from_date`, `#creative_synced_through_date`, `#creative_backfill_attempts`, `#creative_backfill_next_attempt_at`, `AdAccount#today_in_zone`.

- [ ] **Step 1: Write the failing model specs**

```ruby
# spec/models/ad_creative_spec.rb
require "rails_helper"

RSpec.describe AdCreative do
  it "requires a unique asset per account, type and id" do
    account = create(:ad_account)
    create(:ad_creative, ad_account: account, asset_type: "video", asset_id: "v1")
    dup = build(:ad_creative, ad_account: account, asset_type: "video", asset_id: "v1")

    expect(dup).not_to be_valid
    expect(dup.errors[:asset_id]).to be_present
  end

  it "allows the same asset_id under a different asset_type" do
    account = create(:ad_account)
    create(:ad_creative, ad_account: account, asset_type: "video", asset_id: "shared")

    expect(build(:ad_creative, ad_account: account, asset_type: "image", asset_id: "shared")).to be_valid
  end

  it "rejects an unknown asset_type" do
    expect(build(:ad_creative, asset_type: "carousel")).not_to be_valid
  end

  it "nullifies ad_units instead of destroying them" do
    creative = create(:ad_creative)
    unit = create(:ad_unit, ad_account: creative.ad_account, ad_creative: creative)

    creative.destroy!

    expect(unit.reload.ad_creative_id).to be_nil
  end
end
```

```ruby
# spec/models/ad_unit_spec.rb
require "rails_helper"

RSpec.describe AdUnit do
  it "requires a unique ad_id per account" do
    account = create(:ad_account)
    create(:ad_unit, ad_account: account, ad_id: "ad_1")

    expect(build(:ad_unit, ad_account: account, ad_id: "ad_1")).not_to be_valid
  end

  it "allows a null creative for multi-asset ads" do
    expect(build(:ad_unit, ad_creative: nil, multi_asset: true)).to be_valid
  end

  it "destroys its daily metrics" do
    unit = create(:ad_unit)
    create(:ad_unit_daily_metric, ad_unit: unit)

    expect { unit.destroy! }.to change(AdUnitDailyMetric, :count).by(-1)
  end
end
```

```ruby
# spec/models/ad_unit_daily_metric_spec.rb
require "rails_helper"

RSpec.describe AdUnitDailyMetric do
  it "requires a unique date per ad unit" do
    unit = create(:ad_unit)
    create(:ad_unit_daily_metric, ad_unit: unit, date: Date.new(2026, 7, 1))

    expect(build(:ad_unit_daily_metric, ad_unit: unit, date: Date.new(2026, 7, 1))).not_to be_valid
  end

  it "rejects negative spend" do
    expect(build(:ad_unit_daily_metric, spend: -1)).not_to be_valid
  end
end
```

```ruby
# spec/models/ad_account_spec.rb — append inside the existing describe block
  describe "#today_in_zone" do
    it "uses the account timezone rather than the app timezone" do
      account = create(:ad_account, timezone: "Asia/Taipei")

      travel_to Time.utc(2026, 7, 25, 18, 0, 0) do
        expect(account.today_in_zone).to eq(Date.new(2026, 7, 26))
      end
    end

    it "falls back to UTC when the timezone is unknown" do
      account = create(:ad_account)
      account.update_column(:timezone, "Not/AZone")

      travel_to Time.utc(2026, 7, 25, 18, 0, 0) do
        expect(account.today_in_zone).to eq(Date.new(2026, 7, 25))
      end
    end
  end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/models/ad_creative_spec.rb spec/models/ad_unit_spec.rb spec/models/ad_unit_daily_metric_spec.rb`
Expected: FAIL — `uninitialized constant AdCreative`.

- [ ] **Step 3: Write the migrations**

```ruby
# db/migrate/<ts>_create_ad_creatives.rb
class CreateAdCreatives < ActiveRecord::Migration[8.1]
  def change
    create_table :ad_creatives, id: :uuid do |t|
      t.references :ad_account, null: false, foreign_key: true, type: :uuid
      t.string :asset_type, null: false
      t.string :asset_id, null: false
      t.string :name
      t.string :thumbnail_url
      t.integer :duration_seconds
      t.date :first_spend_date

      t.timestamps
    end

    add_index :ad_creatives, [ :ad_account_id, :asset_type, :asset_id ],
      unique: true, name: "idx_ad_creatives_on_account_type_asset"
  end
end
```

```ruby
# db/migrate/<ts>_create_ad_units.rb
class CreateAdUnits < ActiveRecord::Migration[8.1]
  def change
    create_table :ad_units, id: :uuid do |t|
      t.references :ad_account, null: false, foreign_key: true, type: :uuid
      t.references :ad_creative, null: true, foreign_key: true, type: :uuid
      t.references :ad_campaign, null: true, foreign_key: true, type: :uuid
      t.string :ad_id, null: false
      t.string :ad_name
      t.string :adset_id
      t.string :status, default: "active", null: false
      t.boolean :multi_asset, default: false, null: false

      t.timestamps
    end

    add_index :ad_units, [ :ad_account_id, :ad_id ], unique: true
  end
end
```

```ruby
# db/migrate/<ts>_create_ad_unit_daily_metrics.rb
class CreateAdUnitDailyMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :ad_unit_daily_metrics, id: :uuid do |t|
      t.references :ad_unit, null: false, foreign_key: true, type: :uuid
      t.date :date, null: false
      t.decimal :spend, precision: 12, scale: 2, default: 0
      t.integer :impressions, default: 0
      t.integer :clicks, default: 0
      t.integer :inline_link_clicks, default: 0
      t.integer :video_continuous_2_sec_watched, default: 0
      t.integer :video_p25_watched, default: 0
      t.integer :video_p50_watched, default: 0
      t.integer :video_p75_watched, default: 0
      t.integer :video_p95_watched, default: 0
      t.integer :video_p100_watched, default: 0
      t.integer :add_to_cart, default: 0
      t.integer :checkout_initiated, default: 0
      t.integer :purchases, default: 0
      t.decimal :conversion_value, precision: 12, scale: 2, default: 0

      t.timestamps
    end

    add_index :ad_unit_daily_metrics, [ :ad_unit_id, :date ], unique: true,
      name: "idx_ad_unit_metrics_on_unit_date"
    # Range scans across many units filter by date first (§4.3).
    add_index :ad_unit_daily_metrics, [ :date, :ad_unit_id ],
      name: "idx_ad_unit_metrics_on_date_unit"
  end
end
```

```ruby
# db/migrate/<ts>_add_creative_sync_fields_to_ad_accounts.rb
class AddCreativeSyncFieldsToAdAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :ad_accounts, :creative_synced_from_date, :date
    add_column :ad_accounts, :creative_synced_through_date, :date
    add_column :ad_accounts, :creative_backfill_attempts, :integer, default: 0, null: false
    add_column :ad_accounts, :creative_backfill_next_attempt_at, :datetime
  end
end
```

- [ ] **Step 4: Write the models**

```ruby
# app/models/ad_creative.rb
class AdCreative < ApplicationRecord
  ASSET_TYPES = %w[video image].freeze

  belongs_to :ad_account
  # nullify, not destroy: an ad going away must not delete the creative record
  has_many :ad_units, dependent: :nullify

  validates :asset_type, presence: true, inclusion: { in: ASSET_TYPES }
  validates :asset_id, presence: true,
    uniqueness: { scope: [ :ad_account_id, :asset_type ] }

  scope :video, -> { where(asset_type: "video") }
end
```

```ruby
# app/models/ad_unit.rb
class AdUnit < ApplicationRecord
  belongs_to :ad_account
  belongs_to :ad_creative, optional: true
  belongs_to :ad_campaign, optional: true
  has_many :ad_unit_daily_metrics, dependent: :destroy

  validates :ad_id, presence: true, uniqueness: { scope: :ad_account_id }
  validates :status, presence: true, inclusion: { in: %w[active paused deleted] }

  scope :attributable, -> { where(multi_asset: false).where.not(ad_creative_id: nil) }
end
```

```ruby
# app/models/ad_unit_daily_metric.rb
class AdUnitDailyMetric < ApplicationRecord
  belongs_to :ad_unit

  validates :date, presence: true, uniqueness: { scope: :ad_unit_id }
  validates :spend, numericality: { greater_than_or_equal_to: 0 }
end
```

- [ ] **Step 5: Add the AdAccount associations and timezone helper**

In `app/models/ad_account.rb`, add below the existing `has_many :ad_daily_metrics` line:

```ruby
  has_many :ad_creatives, dependent: :destroy
  has_many :ad_units, dependent: :destroy
```

and add this public method:

```ruby
  # Meta insights dates are in the ad account's own timezone, never the app's.
  def today_in_zone
    (ActiveSupport::TimeZone[timezone.to_s] || ActiveSupport::TimeZone["UTC"]).today
  end
```

- [ ] **Step 6: Write the factories**

```ruby
# spec/factories/ad_creatives.rb
FactoryBot.define do
  factory :ad_creative do
    ad_account
    asset_type { "video" }
    sequence(:asset_id) { |n| "video_#{100000 + n}" }
    sequence(:name) { |n| "Creative #{n}" }
    thumbnail_url { "https://example.com/thumb.jpg" }
    duration_seconds { 30 }
    first_spend_date { nil }
  end
end
```

```ruby
# spec/factories/ad_units.rb
FactoryBot.define do
  factory :ad_unit do
    ad_account
    ad_creative { association(:ad_creative, ad_account: ad_account) }
    sequence(:ad_id) { |n| "ad_#{100000 + n}" }
    sequence(:ad_name) { |n| "Ad #{n}" }
    sequence(:adset_id) { |n| "adset_#{100000 + n}" }
    status { "active" }
    multi_asset { false }
  end
end
```

```ruby
# spec/factories/ad_unit_daily_metrics.rb
FactoryBot.define do
  factory :ad_unit_daily_metric do
    ad_unit
    date { Date.current }
    spend { 100.00 }
    impressions { 10_000 }
    clicks { 300 }
    inline_link_clicks { 200 }
    video_continuous_2_sec_watched { 3_000 }
    video_p25_watched { 2_000 }
    video_p50_watched { 1_200 }
    video_p75_watched { 700 }
    video_p95_watched { 400 }
    video_p100_watched { 300 }
    add_to_cart { 20 }
    checkout_initiated { 10 }
    purchases { 5 }
    conversion_value { 400.00 }
  end
end
```

- [ ] **Step 7: Migrate and run the specs**

Run:
```bash
bin/rails db:migrate && bin/rails db:test:prepare
bundle exec rspec spec/models/ad_creative_spec.rb spec/models/ad_unit_spec.rb spec/models/ad_unit_daily_metric_spec.rb spec/models/ad_account_spec.rb
```
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
bin/rubocop -a
git add db/ app/models/ spec/factories/ spec/models/
git commit -m "feat(ads): ad_creatives, ad_units and ad_unit_daily_metrics schema"
```

---

### Task 2: Asset resolution and `sync_ad_units`

**Files:**
- Modify: `app/services/meta_ads_service.rb`
- Test: `spec/services/meta_ads_service_spec.rb`

**Interfaces:**
- Consumes: `AdCreative`, `AdUnit` from Task 1.
- Produces: `MetaAdsService#sync_ad_units` (no args, upserts `ad_units` + `ad_creatives`); private `resolve_asset(creative_data)` returning `{ asset_type:, asset_id:, multi_asset: }` where an unresolved creative yields `{ asset_type: nil, asset_id: nil, multi_asset: false }`.

- [ ] **Step 1: Write the failing specs for `resolve_asset` branch coverage**

Append to `spec/services/meta_ads_service_spec.rb`:

```ruby
  describe "#sync_ad_units" do
    let(:graph) { instance_double(Koala::Facebook::API) }

    before { allow(Koala::Facebook::API).to receive(:new).and_return(graph) }

    def stub_ads(*ads)
      allow(graph).to receive(:get_connections).and_return(ads)
    end

    def ad_payload(id:, creative:)
      {
        "id" => id, "name" => "Ad #{id}", "adset_id" => "adset_1",
        "campaign_id" => "camp_1", "effective_status" => "ACTIVE",
        "creative" => creative
      }
    end

    it "resolves creative.video_id (branch 2)" do
      stub_ads(ad_payload(id: "a1", creative: { "id" => "c1", "video_id" => "v9" }))

      service.sync_ad_units

      unit = AdUnit.find_by(ad_id: "a1")
      expect(unit.multi_asset).to be(false)
      expect(unit.ad_creative.asset_type).to eq("video")
      expect(unit.ad_creative.asset_id).to eq("v9")
    end

    it "resolves object_story_spec video_data (branch 3)" do
      stub_ads(ad_payload(id: "a2", creative: {
        "id" => "c2", "object_story_spec" => { "video_data" => { "video_id" => "v8" } }
      }))

      service.sync_ad_units

      expect(AdUnit.find_by(ad_id: "a2").ad_creative.asset_id).to eq("v8")
    end

    it "resolves a single video inside asset_feed_spec (branch 4)" do
      stub_ads(ad_payload(id: "a3", creative: {
        "id" => "c3", "asset_feed_spec" => { "videos" => [ { "video_id" => "v7" } ] }
      }))

      service.sync_ad_units

      unit = AdUnit.find_by(ad_id: "a3")
      expect(unit.multi_asset).to be(false)
      expect(unit.ad_creative.asset_id).to eq("v7")
    end

    it "resolves creative.image_hash (branch 5)" do
      stub_ads(ad_payload(id: "a4", creative: { "id" => "c4", "image_hash" => "h1" }))

      service.sync_ad_units

      creative = AdUnit.find_by(ad_id: "a4").ad_creative
      expect(creative.asset_type).to eq("image")
      expect(creative.asset_id).to eq("h1")
    end

    it "resolves a single image inside asset_feed_spec (branch 6)" do
      stub_ads(ad_payload(id: "a5", creative: {
        "id" => "c5", "asset_feed_spec" => { "images" => [ { "hash" => "h2" } ] }
      }))

      service.sync_ad_units

      expect(AdUnit.find_by(ad_id: "a5").ad_creative.asset_id).to eq("h2")
    end

    it "resolves link_data image_hash (branch 7)" do
      stub_ads(ad_payload(id: "a6", creative: {
        "id" => "c6", "object_story_spec" => { "link_data" => { "image_hash" => "h3" } }
      }))

      service.sync_ad_units

      expect(AdUnit.find_by(ad_id: "a6").ad_creative.asset_id).to eq("h3")
    end

    it "marks multiple distinct media as multi_asset (branch 1)" do
      stub_ads(ad_payload(id: "a7", creative: {
        "id" => "c7",
        "asset_feed_spec" => { "videos" => [ { "video_id" => "v1" }, { "video_id" => "v2" } ] }
      }))

      service.sync_ad_units

      unit = AdUnit.find_by(ad_id: "a7")
      expect(unit.multi_asset).to be(true)
      expect(unit.ad_creative_id).to be_nil
    end

    it "treats mixed video and image as multi_asset" do
      stub_ads(ad_payload(id: "a8", creative: {
        "id" => "c8",
        "asset_feed_spec" => { "videos" => [ { "video_id" => "v1" } ], "images" => [ { "hash" => "h1" } ] }
      }))

      service.sync_ad_units

      expect(AdUnit.find_by(ad_id: "a8").multi_asset).to be(true)
    end

    it "prefers the multi_asset branch over a residual top-level video_id" do
      stub_ads(ad_payload(id: "a9", creative: {
        "id" => "c9", "video_id" => "residual",
        "asset_feed_spec" => { "videos" => [ { "video_id" => "v1" }, { "video_id" => "v2" } ] }
      }))

      service.sync_ad_units

      unit = AdUnit.find_by(ad_id: "a9")
      expect(unit.multi_asset).to be(true)
      expect(AdCreative.find_by(asset_id: "residual")).to be_nil
    end

    it "counts duplicate media ids as one distinct asset" do
      stub_ads(ad_payload(id: "a10", creative: {
        "id" => "c10",
        "asset_feed_spec" => { "videos" => [ { "video_id" => "v1" }, { "video_id" => "v1" } ] }
      }))

      service.sync_ad_units

      unit = AdUnit.find_by(ad_id: "a10")
      expect(unit.multi_asset).to be(false)
      expect(unit.ad_creative.asset_id).to eq("v1")
    end

    it "attributes a single media asset that also carries customization rules" do
      stub_ads(ad_payload(id: "a11", creative: {
        "id" => "c11",
        "asset_feed_spec" => {
          "videos" => [ { "video_id" => "v1" } ],
          "asset_customization_rules" => [ { "customization_spec" => { "publisher_platforms" => [ "facebook" ] } } ]
        }
      }))

      service.sync_ad_units

      unit = AdUnit.find_by(ad_id: "a11")
      expect(unit.multi_asset).to be(false)
      expect(unit.ad_creative.asset_id).to eq("v1")
    end

    it "leaves an unknown creative shape unattributed without marking multi_asset (branch 8)" do
      stub_ads(ad_payload(id: "a12", creative: { "id" => "c12" }))

      service.sync_ad_units

      unit = AdUnit.find_by(ad_id: "a12")
      expect(unit.ad_creative_id).to be_nil
      expect(unit.multi_asset).to be(false)
    end

    it "links the ad unit to an existing campaign" do
      campaign = create(:ad_campaign, ad_account: ad_account, campaign_id: "camp_1")
      stub_ads(ad_payload(id: "a13", creative: { "id" => "c13", "video_id" => "v1" }))

      service.sync_ad_units

      expect(AdUnit.find_by(ad_id: "a13").ad_campaign).to eq(campaign)
    end

    it "reuses one creative across several ads" do
      stub_ads(
        ad_payload(id: "a14", creative: { "id" => "c14", "video_id" => "shared" }),
        ad_payload(id: "a15", creative: { "id" => "c15", "video_id" => "shared" })
      )

      expect { service.sync_ad_units }.to change(AdCreative, :count).by(1)
      expect(AdUnit.count).to eq(2)
    end

    it "is idempotent across repeated syncs" do
      stub_ads(ad_payload(id: "a16", creative: { "id" => "c16", "video_id" => "v1" }))

      service.sync_ad_units
      expect { service.sync_ad_units }.not_to change(AdUnit, :count)
    end
  end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/services/meta_ads_service_spec.rb -e "#sync_ad_units"`
Expected: FAIL — `undefined method 'sync_ad_units'`.

- [ ] **Step 3: Implement `sync_ad_units` and `resolve_asset`**

Add to the public section of `app/services/meta_ads_service.rb`:

```ruby
  AD_FIELDS = "id,name,adset_id,campaign_id,effective_status," \
              "creative{id,video_id,image_hash,thumbnail_url,object_story_spec,asset_feed_spec}".freeze

  def sync_ad_units
    ads = fetch_all_pages(@ad_account.account_id, "ads", fields: AD_FIELDS, limit: 500)
    campaign_ids = @ad_account.ad_campaigns.pluck(:campaign_id, :id).to_h

    ads.each do |data|
      resolved = resolve_asset(data["creative"] || {})
      creative = find_or_create_creative(resolved, data["name"])

      unit = @ad_account.ad_units.find_or_initialize_by(ad_id: data["id"])
      unit.assign_attributes(
        ad_name: data["name"],
        adset_id: data["adset_id"],
        ad_campaign_id: campaign_ids[data["campaign_id"]],
        status: map_campaign_status(data["effective_status"]),
        multi_asset: resolved[:multi_asset],
        ad_creative: creative
      )
      unit.save!

      if creative.nil? && !resolved[:multi_asset]
        Rails.logger.warn("[SyncAdUnits] unresolved creative shape ad=#{data['id']} account=#{@ad_account.account_id}")
      end
    end
  end
```

Add to the private section:

```ruby
  # Resolution order per spec §5.1. First match wins; the multi-asset check
  # must stay first so a residual video_id on an Advantage+ creative cannot
  # capture the whole ad's spend.
  def resolve_asset(creative)
    feed = creative["asset_feed_spec"] || {}
    videos = Array(feed["videos"]).map { |v| v["video_id"] }.compact.uniq
    images = Array(feed["images"]).map { |i| i["hash"] }.compact.uniq

    return { asset_type: nil, asset_id: nil, multi_asset: true } if videos.size + images.size > 1

    story = creative["object_story_spec"] || {}

    video_id = creative["video_id"].presence ||
               story.dig("video_data", "video_id").presence ||
               videos.first
    return { asset_type: "video", asset_id: video_id, multi_asset: false } if video_id.present?

    image_hash = creative["image_hash"].presence ||
                 images.first ||
                 story.dig("link_data", "image_hash").presence
    return { asset_type: "image", asset_id: image_hash, multi_asset: false } if image_hash.present?

    { asset_type: nil, asset_id: nil, multi_asset: false }
  end

  def find_or_create_creative(resolved, fallback_name)
    return nil if resolved[:asset_id].blank?

    creative = @ad_account.ad_creatives.find_or_initialize_by(
      asset_type: resolved[:asset_type], asset_id: resolved[:asset_id]
    )
    creative.name ||= fallback_name
    creative.save!
    creative
  end
```

- [ ] **Step 4: Run the specs to verify they pass**

Run: `bundle exec rspec spec/services/meta_ads_service_spec.rb -e "#sync_ad_units"`
Expected: PASS (16 examples).

- [ ] **Step 5: Commit**

```bash
bin/rubocop -a
git add app/services/meta_ads_service.rb spec/services/meta_ads_service_spec.rb
git commit -m "feat(ads): sync ad units and resolve creative assets"
```

---

### Task 3: `fetch_ad_insights` and video metric extraction

**Files:**
- Modify: `app/services/meta_ads_service.rb`
- Test: `spec/services/meta_ads_service_spec.rb`

**Interfaces:**
- Consumes: `AdUnit` from Task 1.
- Produces: `MetaAdsService#fetch_ad_insights(start_date, end_date)` returning an array of hashes with symbol keys `:ad_id, :date, :spend, :impressions, :clicks, :inline_link_clicks, :video_continuous_2_sec_watched, :video_p25_watched, :video_p50_watched, :video_p75_watched, :video_p95_watched, :video_p100_watched, :add_to_cart, :checkout_initiated, :purchases, :conversion_value`. **Performs no database writes** — Task 4 writes them inside a transaction, so the API call never happens inside one.

- [ ] **Step 1: Write the failing specs**

Append to `spec/services/meta_ads_service_spec.rb`:

```ruby
  describe "#fetch_ad_insights" do
    let(:graph) { instance_double(Koala::Facebook::API) }

    before { allow(Koala::Facebook::API).to receive(:new).and_return(graph) }

    def insight_row(overrides = {})
      {
        "ad_id" => "a1", "date_start" => "2026-07-01",
        "spend" => "12.50", "impressions" => "1000", "clicks" => "40",
        "inline_link_clicks" => "30",
        "video_continuous_2_sec_watched_actions" => [ { "action_type" => "video_view", "value" => "300" } ],
        "video_p25_watched_actions" => [ { "action_type" => "video_view", "value" => "250" } ],
        "video_p50_watched_actions" => [ { "action_type" => "video_view", "value" => "150" } ],
        "video_p75_watched_actions" => [ { "action_type" => "video_view", "value" => "90" } ],
        "video_p95_watched_actions" => [ { "action_type" => "video_view", "value" => "50" } ],
        "video_p100_watched_actions" => [ { "action_type" => "video_view", "value" => "40" } ],
        "actions" => [
          { "action_type" => "offsite_conversion.fb_pixel_add_to_cart", "value" => "8" },
          { "action_type" => "offsite_conversion.fb_pixel_initiate_checkout", "value" => "4" },
          { "action_type" => "offsite_conversion.fb_pixel_purchase", "value" => "2" }
        ],
        "action_values" => [
          { "action_type" => "offsite_conversion.fb_pixel_purchase", "value" => "88.00" }
        ]
      }.merge(overrides)
    end

    it "parses list-valued video fields into integers" do
      allow(graph).to receive(:get_connections).and_return([ insight_row ])

      row = service.fetch_ad_insights(Date.new(2026, 7, 1), Date.new(2026, 7, 1)).first

      expect(row[:video_continuous_2_sec_watched]).to eq(300)
      expect(row[:video_p50_watched]).to eq(150)
      expect(row[:video_p75_watched]).to eq(90)
    end

    it "sums every entry in a video action list" do
      allow(graph).to receive(:get_connections).and_return([
        insight_row("video_p50_watched_actions" => [
          { "action_type" => "video_view", "value" => "100" },
          { "action_type" => "something_new", "value" => "20" }
        ])
      ])

      row = service.fetch_ad_insights(Date.new(2026, 7, 1), Date.new(2026, 7, 1)).first

      expect(row[:video_p50_watched]).to eq(120)
    end

    it "returns zero for absent video fields (image ads)" do
      allow(graph).to receive(:get_connections).and_return([
        insight_row.except(
          "video_continuous_2_sec_watched_actions", "video_p25_watched_actions",
          "video_p50_watched_actions", "video_p75_watched_actions",
          "video_p95_watched_actions", "video_p100_watched_actions"
        )
      ])

      row = service.fetch_ad_insights(Date.new(2026, 7, 1), Date.new(2026, 7, 1)).first

      expect(row[:video_p50_watched]).to eq(0)
      expect(row[:video_continuous_2_sec_watched]).to eq(0)
    end

    it "parses conversions with the full offsite_conversion action types" do
      allow(graph).to receive(:get_connections).and_return([ insight_row ])

      row = service.fetch_ad_insights(Date.new(2026, 7, 1), Date.new(2026, 7, 1)).first

      expect(row[:add_to_cart]).to eq(8)
      expect(row[:checkout_initiated]).to eq(4)
      expect(row[:purchases]).to eq(2)
      expect(row[:conversion_value]).to eq(88.00)
    end

    it "requests account attribution settings and ad-level daily granularity" do
      expect(graph).to receive(:get_connections) do |_node, edge, **params|
        expect(edge).to eq("insights")
        expect(params[:level]).to eq("ad")
        expect(params[:time_increment]).to eq(1)
        expect(params[:use_account_attribution_setting]).to be(true)
        expect(params[:limit]).to eq(500)
        expect(params[:time_range]).to eq({ since: "2026-07-01", until: "2026-07-03" })
        []
      end

      service.fetch_ad_insights(Date.new(2026, 7, 1), Date.new(2026, 7, 3))
    end

    it "writes nothing to the database" do
      allow(graph).to receive(:get_connections).and_return([ insight_row ])

      expect {
        service.fetch_ad_insights(Date.new(2026, 7, 1), Date.new(2026, 7, 1))
      }.not_to change(AdUnitDailyMetric, :count)
    end
  end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/services/meta_ads_service_spec.rb -e "#fetch_ad_insights"`
Expected: FAIL — `undefined method 'fetch_ad_insights'`.

- [ ] **Step 3: Implement `fetch_ad_insights` and `extract_video_metric`**

Add to the public section of `app/services/meta_ads_service.rb`:

```ruby
  INSIGHT_FIELDS = %w[
    ad_id spend impressions clicks inline_link_clicks actions action_values
    video_continuous_2_sec_watched_actions
    video_p25_watched_actions video_p50_watched_actions
    video_p75_watched_actions video_p95_watched_actions video_p100_watched_actions
  ].join(",").freeze

  # Fetches one date range and returns parsed rows. Deliberately performs no
  # writes: the caller persists them together with the coverage advance inside
  # a single transaction (spec §5.6), and an HTTP call must not sit inside one.
  def fetch_ad_insights(start_date, end_date)
    rows = fetch_all_pages(
      @ad_account.account_id, "insights",
      fields: INSIGHT_FIELDS,
      level: "ad",
      time_increment: 1,
      use_account_attribution_setting: true,
      time_range: { since: start_date.iso8601, until: end_date.iso8601 },
      limit: 500
    )

    rows.map do |row|
      {
        ad_id: row["ad_id"],
        date: Date.parse(row["date_start"]),
        spend: row["spend"].to_d,
        impressions: row["impressions"].to_i,
        clicks: row["clicks"].to_i,
        inline_link_clicks: row["inline_link_clicks"].to_i,
        video_continuous_2_sec_watched: extract_video_metric(row["video_continuous_2_sec_watched_actions"]),
        video_p25_watched: extract_video_metric(row["video_p25_watched_actions"]),
        video_p50_watched: extract_video_metric(row["video_p50_watched_actions"]),
        video_p75_watched: extract_video_metric(row["video_p75_watched_actions"]),
        video_p95_watched: extract_video_metric(row["video_p95_watched_actions"]),
        video_p100_watched: extract_video_metric(row["video_p100_watched_actions"]),
        add_to_cart: extract_action_count(row["actions"], "offsite_conversion.fb_pixel_add_to_cart"),
        checkout_initiated: extract_action_count(row["actions"], "offsite_conversion.fb_pixel_initiate_checkout"),
        purchases: extract_action_count(row["actions"], "offsite_conversion.fb_pixel_purchase"),
        conversion_value: extract_action_value(row["action_values"], "offsite_conversion.fb_pixel_purchase")
      }
    end
  end
```

Add to the private section:

```ruby
  # Video insight fields are list<AdsActionStats>, not scalars (spec §2.3).
  # Sum every entry rather than picking action_type == "video_view", so a new
  # action_type from Meta cannot silently drop counts.
  def extract_video_metric(list)
    return 0 if list.blank?

    list.sum { |entry| entry["value"].to_i }
  end
```

- [ ] **Step 4: Run the specs to verify they pass**

Run: `bundle exec rspec spec/services/meta_ads_service_spec.rb -e "#fetch_ad_insights"`
Expected: PASS (6 examples).

- [ ] **Step 5: Commit**

```bash
bin/rubocop -a
git add app/services/meta_ads_service.rb spec/services/meta_ads_service_spec.rb
git commit -m "feat(ads): fetch ad-level insights with list-valued video metrics"
```

---

### Task 4: `AdCreativeBackfillService` — segmentation, coverage, `first_spend_date`

**Files:**
- Create: `app/services/ad_creative_backfill_service.rb`
- Test: `spec/services/ad_creative_backfill_service_spec.rb`

**Interfaces:**
- Consumes: `MetaAdsService#fetch_ad_insights` (Task 3), `AdAccount#today_in_zone` (Task 1).
- Produces: `AdCreativeBackfillService.new(ad_account, meta_service: nil)` with `#call(days: 90)` returning `true` on full success and `false` when a segment failed; `#sync_range(start_date, end_date)` used by the rolling job in Task 6.

- [ ] **Step 1: Write the failing specs**

```ruby
# spec/services/ad_creative_backfill_service_spec.rb
require "rails_helper"

RSpec.describe AdCreativeBackfillService do
  let(:ad_account) { create(:ad_account, timezone: "UTC") }
  let(:meta) { instance_double(MetaAdsService) }
  let(:service) { described_class.new(ad_account, meta_service: meta) }
  let(:today) { Date.new(2026, 7, 25) }

  before do
    allow(meta).to receive(:refresh_token_if_needed!)
    allow(meta).to receive(:sync_ad_units)
    allow(meta).to receive(:sync_creative_assets)
    allow(ad_account).to receive(:today_in_zone).and_return(today)
    create(:ad_unit, ad_account: ad_account, ad_id: "a1")
  end

  def row(date, spend: 10, purchases: 1, value: 20)
    { ad_id: "a1", date: date, spend: spend, impressions: 100, clicks: 5,
      inline_link_clicks: 4, video_continuous_2_sec_watched: 30,
      video_p25_watched: 25, video_p50_watched: 15, video_p75_watched: 9,
      video_p95_watched: 5, video_p100_watched: 4, add_to_cart: 2,
      checkout_initiated: 1, purchases: purchases, conversion_value: value }
  end

  describe "mode A (initialize)" do
    it "sets both coverage bounds and spans the full window" do
      allow(meta).to receive(:fetch_ad_insights).and_return([ row(today) ])

      service.call(days: 90)

      ad_account.reload
      expect(ad_account.creative_synced_from_date).to eq(today - 89)
      expect(ad_account.creative_synced_through_date).to eq(today)
    end

    it "runs when only one bound is null" do
      ad_account.update_columns(creative_synced_from_date: today - 10, creative_synced_through_date: nil)
      allow(meta).to receive(:fetch_ad_insights).and_return([])

      service.call(days: 90)

      expect(ad_account.reload.creative_synced_from_date).to eq(today - 89)
    end

    it "chunks the window into 30-day segments oldest first" do
      ranges = []
      allow(meta).to receive(:fetch_ad_insights) { |from, to| ranges << [ from, to ]; [] }

      service.call(days: 90)

      expect(ranges.size).to eq(3)
      expect(ranges.first.first).to eq(today - 89)
      expect(ranges.last.last).to eq(today)
      expect(ranges).to eq(ranges.sort_by(&:first))
    end
  end

  describe "mode B (forward resume)" do
    it "resumes from the day after the current through date" do
      ad_account.update_columns(creative_synced_from_date: today - 89, creative_synced_through_date: today - 5)
      ranges = []
      allow(meta).to receive(:fetch_ad_insights) { |from, to| ranges << [ from, to ]; [] }

      service.call(days: 90)

      expect(ranges.first.first).to eq(today - 4)
      expect(ad_account.reload.creative_synced_from_date).to eq(today - 89)
      expect(ad_account.reload.creative_synced_through_date).to eq(today)
    end
  end

  describe "segment failure" do
    it "aborts the run, keeps earlier segments and never sends later ones" do
      calls = []
      allow(meta).to receive(:fetch_ad_insights) do |from, to|
        calls << [ from, to ]
        raise Koala::Facebook::APIError.new(500, "boom") if calls.size == 2
        []
      end

      expect(service.call(days: 90)).to be(false)

      expect(calls.size).to eq(2)
      expect(ad_account.reload.creative_synced_through_date).to eq(today - 60)
    end

    it "never leaves metric rows outside the coverage interval" do
      calls = []
      allow(meta).to receive(:fetch_ad_insights) do |from, to|
        calls << [ from, to ]
        raise Koala::Facebook::APIError.new(500, "boom") if calls.size == 2
        [ row(from) ]
      end

      service.call(days: 90)

      ad_account.reload
      dates = AdUnitDailyMetric.joins(:ad_unit).where(ad_units: { ad_account_id: ad_account.id }).pluck(:date)
      expect(dates).to all(be_between(ad_account.creative_synced_from_date, ad_account.creative_synced_through_date))
    end
  end

  describe "first_spend_date" do
    it "records the earliest day with spend above zero" do
      creative = create(:ad_creative, ad_account: ad_account)
      AdUnit.find_by(ad_id: "a1").update!(ad_creative: creative)
      allow(meta).to receive(:fetch_ad_insights).and_return([
        row(today - 3, spend: 0), row(today - 2, spend: 5), row(today - 1, spend: 7)
      ])

      service.call(days: 90)

      expect(creative.reload.first_spend_date).to eq(today - 2)
    end

    it "leaves first_spend_date null when the creative never spent" do
      creative = create(:ad_creative, ad_account: ad_account)
      AdUnit.find_by(ad_id: "a1").update!(ad_creative: creative)
      allow(meta).to receive(:fetch_ad_insights).and_return([ row(today, spend: 0) ])

      service.call(days: 90)

      expect(creative.reload.first_spend_date).to be_nil
    end
  end

  describe "upsert" do
    it "updates an existing row rather than duplicating it" do
      allow(meta).to receive(:fetch_ad_insights).and_return([ row(today, spend: 10) ])
      service.call(days: 90)

      allow(meta).to receive(:fetch_ad_insights).and_return([ row(today, spend: 99) ])
      service.call(days: 90)

      metrics = AdUnitDailyMetric.joins(:ad_unit).where(ad_units: { ad_account_id: ad_account.id })
      expect(metrics.count).to eq(1)
      expect(metrics.first.spend).to eq(99)
    end

    it "ignores rows for ads that are not synced yet" do
      allow(meta).to receive(:fetch_ad_insights).and_return([ row(today).merge(ad_id: "unknown") ])

      expect { service.call(days: 90) }.not_to change(AdUnitDailyMetric, :count)
    end
  end
end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/services/ad_creative_backfill_service_spec.rb`
Expected: FAIL — `uninitialized constant AdCreativeBackfillService`.

- [ ] **Step 3: Implement the service**

```ruby
# app/services/ad_creative_backfill_service.rb
class AdCreativeBackfillService
  SEGMENT_DAYS = 30

  def initialize(ad_account, meta_service: nil)
    @ad_account = ad_account
    @meta = meta_service || MetaAdsService.new(ad_account)
  end

  # Returns true when every segment succeeded, false when the run aborted.
  def call(days: 90)
    @meta.refresh_token_if_needed!
    @meta.sync_ad_units

    today = @ad_account.today_in_zone
    start_date = resolve_start_date(today, days)
    return true if start_date > today

    initializing = coverage_incomplete?

    segments(start_date, today).each_with_index do |(from, to), index|
      rows = @meta.fetch_ad_insights(from, to)
      persist_segment(rows, from, to, initialize_bounds: initializing && index.zero?)
    rescue Koala::Facebook::APIError, Koala::Facebook::ClientError => e
      Rails.logger.error("[AdCreativeBackfill] account=#{@ad_account.account_id} segment=#{from}..#{to}: #{e.message}")
      return false
    end

    @meta.sync_creative_assets
    true
  end

  # Used by the rolling job: one segment, forward append only.
  def sync_range(start_date, end_date)
    rows = @meta.fetch_ad_insights(start_date, end_date)
    persist_segment(rows, start_date, end_date, initialize_bounds: false)
    true
  rescue Koala::Facebook::APIError, Koala::Facebook::ClientError => e
    Rails.logger.error("[AdCreativeRolling] account=#{@ad_account.account_id}: #{e.message}")
    false
  end

  private

  def coverage_incomplete?
    @ad_account.creative_synced_from_date.nil? || @ad_account.creative_synced_through_date.nil?
  end

  # Mode A when either bound is null (a half-null state is corruption; the only
  # safe response is a full rebuild). Mode B otherwise. Mode C is out of scope.
  def resolve_start_date(today, days)
    return today - (days - 1) if coverage_incomplete?

    @ad_account.creative_synced_through_date + 1
  end

  def segments(start_date, end_date)
    result = []
    cursor = start_date
    while cursor <= end_date
      stop = [ cursor + (SEGMENT_DAYS - 1), end_date ].min
      result << [ cursor, stop ]
      cursor = stop + 1
    end
    result
  end

  # Metric writes and the coverage advance share one transaction so the
  # invariant can never be observed broken (spec §5.6).
  def persist_segment(rows, from, to, initialize_bounds:)
    unit_ids = @ad_account.ad_units.pluck(:ad_id, :id).to_h

    ActiveRecord::Base.transaction do
      rows.each do |row|
        unit_id = unit_ids[row[:ad_id]]
        next if unit_id.nil?

        metric = AdUnitDailyMetric.find_or_initialize_by(ad_unit_id: unit_id, date: row[:date])
        metric.assign_attributes(row.except(:ad_id, :date))
        metric.save!
      end

      if initialize_bounds
        @ad_account.update!(creative_synced_from_date: from, creative_synced_through_date: to)
      else
        @ad_account.update!(creative_synced_through_date: to)
      end

      recompute_first_spend_dates
    end
  end

  def recompute_first_spend_dates
    earliest = AdUnitDailyMetric
      .joins(:ad_unit)
      .where(ad_units: { ad_account_id: @ad_account.id })
      .where("ad_units.ad_creative_id IS NOT NULL")
      .where("ad_unit_daily_metrics.spend > 0")
      .group("ad_units.ad_creative_id")
      .minimum("ad_unit_daily_metrics.date")

    earliest.each do |creative_id, date|
      AdCreative.where(id: creative_id).update_all(first_spend_date: date)
    end
  end
end
```

- [ ] **Step 4: Run the specs to verify they pass**

Run: `bundle exec rspec spec/services/ad_creative_backfill_service_spec.rb`
Expected: PASS (11 examples).

- [ ] **Step 5: Commit**

```bash
bin/rubocop -a
git add app/services/ad_creative_backfill_service.rb spec/services/ad_creative_backfill_service_spec.rb
git commit -m "feat(ads): backfill service with contiguous coverage advancement"
```

---

### Task 5: Backfill throttle and `BackfillAdCreativesJob`

**Files:**
- Modify: `app/models/ad_account.rb`
- Create: `app/jobs/backfill_ad_creatives_job.rb`
- Test: `spec/models/ad_account_spec.rb`, `spec/jobs/backfill_ad_creatives_job_spec.rb`

**Interfaces:**
- Consumes: `AdCreativeBackfillService` (Task 4).
- Produces: `AdAccount#claim_backfill_slot!(manual: false)` returning `true` when the slot was claimed; `AdAccount#release_backfill_slot!` clearing `attempts` and `next_attempt_at`; `BackfillAdCreativesJob.perform_later(ad_account_id:, days: 90)`.

- [ ] **Step 1: Write the failing specs**

Append to `spec/models/ad_account_spec.rb`:

```ruby
  describe "#claim_backfill_slot!" do
    let(:account) { create(:ad_account) }

    it "claims when no attempt is scheduled" do
      expect(account.claim_backfill_slot!).to be(true)
      expect(account.reload.creative_backfill_attempts).to eq(1)
      expect(account.creative_backfill_next_attempt_at).to be_present
    end

    it "refuses a second automatic claim inside the backoff window" do
      account.claim_backfill_slot!

      expect(account.claim_backfill_slot!).to be(false)
      expect(account.reload.creative_backfill_attempts).to eq(1)
    end

    it "backs off exponentially and never schedules under one hour out" do
      3.times do
        account.claim_backfill_slot!
        account.update_column(:creative_backfill_next_attempt_at, 1.second.ago)
      end
      account.reload

      account.update_column(:creative_backfill_next_attempt_at, nil)
      account.claim_backfill_slot!

      gap = account.reload.creative_backfill_next_attempt_at - Time.current
      expect(gap).to be >= 1.hour
      expect(gap).to be <= 24.hours
    end

    it "caps the backoff at 24 hours" do
      account.update_column(:creative_backfill_attempts, 20)
      account.claim_backfill_slot!

      gap = account.reload.creative_backfill_next_attempt_at - Time.current
      expect(gap).to be <= 24.hours + 1.minute
    end

    it "lets a manual claim bypass failure backoff" do
      account.update_columns(
        creative_backfill_attempts: 5,
        creative_backfill_next_attempt_at: 20.hours.from_now
      )

      expect(account.claim_backfill_slot!(manual: true)).to be(true)
    end

    it "does not increment attempts on a manual claim" do
      account.update_columns(creative_backfill_attempts: 5, creative_backfill_next_attempt_at: 20.hours.from_now)

      account.claim_backfill_slot!(manual: true)

      expect(account.reload.creative_backfill_attempts).to eq(5)
    end

    it "blocks a rapid second manual click after a clean state" do
      expect(account.claim_backfill_slot!(manual: true)).to be(true)
      expect(account.claim_backfill_slot!(manual: true)).to be(false)
    end

    it "refuses an automatic claim while a manual one holds the slot" do
      account.claim_backfill_slot!(manual: true)

      expect(account.claim_backfill_slot!).to be(false)
    end
  end

  describe "#release_backfill_slot!" do
    it "clears the attempt counter and schedule" do
      account = create(:ad_account, creative_backfill_attempts: 4, creative_backfill_next_attempt_at: 2.hours.from_now)

      account.release_backfill_slot!

      expect(account.reload.creative_backfill_attempts).to eq(0)
      expect(account.creative_backfill_next_attempt_at).to be_nil
    end
  end
```

```ruby
# spec/jobs/backfill_ad_creatives_job_spec.rb
require "rails_helper"

RSpec.describe BackfillAdCreativesJob do
  let(:ad_account) { create(:ad_account) }

  it "releases the throttle slot after a successful run" do
    ad_account.update_columns(creative_backfill_attempts: 3, creative_backfill_next_attempt_at: 5.hours.from_now)
    service = instance_double(AdCreativeBackfillService, call: true)
    allow(AdCreativeBackfillService).to receive(:new).and_return(service)

    described_class.perform_now(ad_account_id: ad_account.id)

    expect(ad_account.reload.creative_backfill_attempts).to eq(0)
    expect(ad_account.creative_backfill_next_attempt_at).to be_nil
  end

  it "leaves the backoff in place after a failed run" do
    ad_account.update_columns(creative_backfill_attempts: 3, creative_backfill_next_attempt_at: 5.hours.from_now)
    service = instance_double(AdCreativeBackfillService, call: false)
    allow(AdCreativeBackfillService).to receive(:new).and_return(service)

    described_class.perform_now(ad_account_id: ad_account.id)

    expect(ad_account.reload.creative_backfill_attempts).to eq(3)
  end

  it "skips an account whose token has expired" do
    ad_account.update_column(:token_expires_at, 1.day.ago)
    expect(AdCreativeBackfillService).not_to receive(:new)

    described_class.perform_now(ad_account_id: ad_account.id)
  end

  it "does not raise when the account no longer exists" do
    expect { described_class.perform_now(ad_account_id: SecureRandom.uuid) }.not_to raise_error
  end

  it "rescues an unexpected error and logs it" do
    allow(AdCreativeBackfillService).to receive(:new).and_raise(StandardError, "kaboom")
    expect(Rails.logger).to receive(:error).with(/kaboom/)

    expect { described_class.perform_now(ad_account_id: ad_account.id) }.not_to raise_error
  end
end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/models/ad_account_spec.rb spec/jobs/backfill_ad_creatives_job_spec.rb`
Expected: FAIL — `undefined method 'claim_backfill_slot!'`.

- [ ] **Step 3: Implement the throttle on `AdAccount`**

Add to `app/models/ad_account.rb`:

```ruby
  # Single atomic conditional UPDATE: checking the due time and advancing it
  # must not be two statements, or two concurrent runners both pass the check
  # and each enqueue a job (spec §5.6).
  #
  # next_attempt_at advances at CLAIM time, not on completion, so it also
  # guards against a still-running backfill without inspecting the queue.
  #
  # Manual claims bypass failure backoff (attempts > 0) because the user asked
  # for a retry, but still respect a 1-hour window set by a previous manual
  # click or a clean state, which is what stops rapid double-clicks. Manual
  # claims never increment attempts: that counter means "consecutive failures"
  # and drives both backoff and future alerting.
  def claim_backfill_slot!(manual: false)
    now = Time.current
    scope = AdAccount.where(id: id)

    scope = if manual
      scope.where(
        "creative_backfill_next_attempt_at IS NULL " \
        "OR creative_backfill_next_attempt_at <= ? " \
        "OR creative_backfill_attempts > 0", now
      )
    else
      scope.where(
        "creative_backfill_next_attempt_at IS NULL OR creative_backfill_next_attempt_at <= ?", now
      )
    end

    affected = if manual
      scope.update_all([ "creative_backfill_next_attempt_at = ?", now + 1.hour ])
    else
      scope.update_all(
        "creative_backfill_attempts = creative_backfill_attempts + 1, " \
        "creative_backfill_next_attempt_at = NOW() + " \
        "(LEAST(GREATEST(POWER(2, creative_backfill_attempts + 1), 1), 24) || ' hours')::interval"
      )
    end

    affected == 1
  end

  def release_backfill_slot!
    update_columns(creative_backfill_attempts: 0, creative_backfill_next_attempt_at: nil)
  end
```

- [ ] **Step 4: Implement the job**

```ruby
# app/jobs/backfill_ad_creatives_job.rb
class BackfillAdCreativesJob < ApplicationJob
  queue_as :default

  def perform(ad_account_id:, days: 90)
    account = AdAccount.find_by(id: ad_account_id)
    return if account.nil?
    return if account.token_expired?

    # Only a clean run clears the backoff; a failed run leaves the schedule
    # set by the claim in place so the next attempt is spaced out.
    account.release_backfill_slot! if AdCreativeBackfillService.new(account).call(days: days)
  rescue => e
    Rails.logger.error("[BackfillAdCreatives] account=#{ad_account_id}: #{e.message}")
  end
end
```

- [ ] **Step 5: Run the specs to verify they pass**

Run: `bundle exec rspec spec/models/ad_account_spec.rb spec/jobs/backfill_ad_creatives_job_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
bin/rubocop -a
git add app/models/ad_account.rb app/jobs/backfill_ad_creatives_job.rb spec/models/ad_account_spec.rb spec/jobs/backfill_ad_creatives_job_spec.rb
git commit -m "feat(ads): atomic backfill throttle and backfill job"
```

---

### Task 6: `SyncAdCreativesJob` — rolling sync and self-healing

**Files:**
- Create: `app/jobs/sync_ad_creatives_job.rb`
- Modify: `config/recurring.yml`, `app/controllers/meta_oauth_controller.rb`
- Test: `spec/jobs/sync_ad_creatives_job_spec.rb`

**Interfaces:**
- Consumes: `AdAccount#claim_backfill_slot!` (Task 5), `BackfillAdCreativesJob` (Task 5), `AdCreativeBackfillService#sync_range` (Task 4).
- Produces: `SyncAdCreativesJob.perform_later(company_id: nil, min_lookback_days: 7)`.

- [ ] **Step 1: Write the failing specs**

```ruby
# spec/jobs/sync_ad_creatives_job_spec.rb
require "rails_helper"

RSpec.describe SyncAdCreativesJob do
  let(:today) { Date.new(2026, 7, 25) }
  let!(:ad_account) { create(:ad_account, timezone: "UTC") }

  before do
    allow_any_instance_of(AdAccount).to receive(:today_in_zone).and_return(today)
  end

  def make_eligible(through: today)
    ad_account.update_columns(creative_synced_from_date: today - 89, creative_synced_through_date: through)
  end

  describe "eligibility" do
    it "syncs an account whose coverage reaches today" do
      make_eligible(through: today)
      service = instance_double(AdCreativeBackfillService)
      allow(AdCreativeBackfillService).to receive(:new).and_return(service)
      expect(service).to receive(:sync_range).and_return(true)

      described_class.perform_now
    end

    it "syncs an account whose coverage reaches yesterday" do
      make_eligible(through: today - 1)
      service = instance_double(AdCreativeBackfillService)
      allow(AdCreativeBackfillService).to receive(:new).and_return(service)
      expect(service).to receive(:sync_range).and_return(true)

      described_class.perform_now
    end
  end

  describe "self-healing" do
    it "enqueues a backfill for an account that has never synced" do
      expect {
        described_class.perform_now
      }.to have_enqueued_job(BackfillAdCreativesJob).with(ad_account_id: ad_account.id, days: 90)
    end

    it "enqueues a backfill when coverage has fallen more than a day behind" do
      make_eligible(through: today - 5)

      expect {
        described_class.perform_now
      }.to have_enqueued_job(BackfillAdCreativesJob)
    end

    it "does not enqueue a backfill for an eligible account" do
      make_eligible(through: today)
      allow_any_instance_of(AdCreativeBackfillService).to receive(:sync_range).and_return(true)

      expect { described_class.perform_now }.not_to have_enqueued_job(BackfillAdCreativesJob)
    end

    it "warns when an account is ineligible" do
      expect(Rails.logger).to receive(:warn).with(/#{ad_account.account_id}/)

      described_class.perform_now
    end
  end

  describe "throttling" do
    it "does not enqueue twice for the same account on consecutive runs" do
      described_class.perform_now

      expect { described_class.perform_now }.not_to have_enqueued_job(BackfillAdCreativesJob)
    end
  end

  describe "lookback" do
    it "syncs at least min_lookback_days back from today" do
      make_eligible(through: today)
      service = instance_double(AdCreativeBackfillService)
      allow(AdCreativeBackfillService).to receive(:new).and_return(service)

      expect(service).to receive(:sync_range).with(today - 6, today).and_return(true)

      described_class.perform_now(min_lookback_days: 7)
    end
  end

  describe "resilience" do
    it "skips an account whose token has expired" do
      ad_account.update_column(:token_expires_at, 1.day.ago)
      expect(AdCreativeBackfillService).not_to receive(:new)

      described_class.perform_now
    end

    it "continues to other accounts after one raises" do
      make_eligible(through: today)
      other = create(:ad_account, timezone: "UTC")
      other.update_columns(creative_synced_from_date: today - 89, creative_synced_through_date: today)

      call_count = 0
      allow_any_instance_of(AdCreativeBackfillService).to receive(:sync_range) do
        call_count += 1
        raise StandardError, "boom" if call_count == 1
        true
      end

      described_class.perform_now

      expect(call_count).to eq(2)
    end

    it "scopes to one company when company_id is given" do
      other_company_account = create(:ad_account)
      other_company_account.update_columns(creative_synced_from_date: today - 89, creative_synced_through_date: today)
      make_eligible(through: today)

      seen = []
      allow(AdCreativeBackfillService).to receive(:new) do |account|
        seen << account.id
        instance_double(AdCreativeBackfillService, sync_range: true)
      end

      described_class.perform_now(company_id: ad_account.company_id)

      expect(seen).to eq([ ad_account.id ])
    end
  end
end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/jobs/sync_ad_creatives_job_spec.rb`
Expected: FAIL — `uninitialized constant SyncAdCreativesJob`.

- [ ] **Step 3: Implement the job**

```ruby
# app/jobs/sync_ad_creatives_job.rb
class SyncAdCreativesJob < ApplicationJob
  queue_as :default

  BACKFILL_DAYS = 90

  def perform(company_id: nil, min_lookback_days: 7)
    scope = AdAccount.meta
    scope = scope.where(company_id: company_id) if company_id

    scope.find_each do |account|
      next if account.token_expired?

      if eligible_for_rolling?(account)
        sync_rolling(account, min_lookback_days)
      else
        heal(account)
      end
    rescue => e
      Rails.logger.error("[SyncAdCreatives] account=#{account.account_id}: #{e.message}")
    end
  end

  private

  # Rolling sync may only append next to an existing contiguous interval.
  # Writing recent days ahead of an unfinished backfill would punch a hole and
  # break the coverage invariant (spec §5.6).
  def eligible_for_rolling?(account)
    through = account.creative_synced_through_date
    account.creative_synced_from_date.present? && through.present? &&
      through >= account.today_in_zone - 1
  end

  def sync_rolling(account, min_lookback_days)
    today = account.today_in_zone
    lookback = [ attribution_window_days(account), min_lookback_days ].compact.max
    AdCreativeBackfillService.new(account).sync_range(today - (lookback - 1), today)
  end

  # Account-level attribution settings are not exposed on the stored record
  # yet, so the floor applies. Wired here so a future lookup has one home.
  def attribution_window_days(_account)
    nil
  end

  # An ineligible account must never be silently skipped: pre-existing accounts
  # get no connect event and a retry-exhausted backfill is never re-enqueued,
  # so this is the only recovery path (spec §5.6).
  def heal(account)
    Rails.logger.warn(
      "[SyncAdCreatives] ineligible account=#{account.account_id} " \
      "from=#{account.creative_synced_from_date} through=#{account.creative_synced_through_date}"
    )
    return unless account.claim_backfill_slot!

    BackfillAdCreativesJob.perform_later(ad_account_id: account.id, days: BACKFILL_DAYS)
  end
end
```

- [ ] **Step 4: Register the recurring schedule**

In `config/recurring.yml`, add the same block under **both** the `production:` and `development:` keys, next to `sync_ad_campaigns`:

```yaml
  sync_ad_creatives:
    class: SyncAdCreativesJob
    schedule: every 1 hour
```

- [ ] **Step 5: Enqueue a backfill when an account is connected**

In `app/controllers/meta_oauth_controller.rb`, immediately after the `ad_account.assign_attributes(...)`/save block that persists a newly connected account (around line 82), add:

```ruby
      if ad_account.saved_change_to_id? && ad_account.claim_backfill_slot!
        BackfillAdCreativesJob.perform_later(ad_account_id: ad_account.id, days: 90)
      end
```

- [ ] **Step 6: Run the specs to verify they pass**

Run: `bundle exec rspec spec/jobs/sync_ad_creatives_job_spec.rb`
Expected: PASS (12 examples).

- [ ] **Step 7: Commit**

```bash
bin/rubocop -a
git add app/jobs/sync_ad_creatives_job.rb config/recurring.yml app/controllers/meta_oauth_controller.rb spec/jobs/sync_ad_creatives_job_spec.rb
git commit -m "feat(ads): rolling creative sync with self-healing backfill enqueue"
```

---

### Task 7: `sync_creative_assets` — thumbnails and durations

**Files:**
- Modify: `app/services/meta_ads_service.rb`
- Test: `spec/services/meta_ads_service_spec.rb`

**Interfaces:**
- Consumes: `AdCreative` (Task 1).
- Produces: `MetaAdsService#sync_creative_assets` — already called by `AdCreativeBackfillService#call` in Task 4.

- [ ] **Step 1: Write the failing specs**

Append to `spec/services/meta_ads_service_spec.rb`:

```ruby
  describe "#sync_creative_assets" do
    let(:graph) { instance_double(Koala::Facebook::API) }

    before { allow(Koala::Facebook::API).to receive(:new).and_return(graph) }

    it "backfills name, duration and thumbnail for a video creative" do
      creative = create(:ad_creative, ad_account: ad_account, asset_type: "video",
        asset_id: "v1", thumbnail_url: nil, name: nil, duration_seconds: nil)
      allow(graph).to receive(:get_object).with("v1", fields: "title,length,thumbnails,picture")
        .and_return({ "title" => "Hook A", "length" => "27.5", "picture" => "https://x/t.jpg" })

      service.sync_creative_assets

      creative.reload
      expect(creative.name).to eq("Hook A")
      expect(creative.duration_seconds).to eq(27)
      expect(creative.thumbnail_url).to eq("https://x/t.jpg")
    end

    it "skips creatives that already have a thumbnail" do
      create(:ad_creative, ad_account: ad_account, asset_type: "video", thumbnail_url: "https://x/have.jpg")
      expect(graph).not_to receive(:get_object)

      service.sync_creative_assets
    end

    it "skips image creatives" do
      create(:ad_creative, ad_account: ad_account, asset_type: "image", asset_id: "h1", thumbnail_url: nil)
      expect(graph).not_to receive(:get_object)

      service.sync_creative_assets
    end

    it "keeps an existing name when the video has no title" do
      creative = create(:ad_creative, ad_account: ad_account, asset_type: "video",
        asset_id: "v2", name: "Existing", thumbnail_url: nil)
      allow(graph).to receive(:get_object).and_return({ "picture" => "https://x/t.jpg" })

      service.sync_creative_assets

      expect(creative.reload.name).to eq("Existing")
    end

    it "logs and continues when one video lookup fails" do
      create(:ad_creative, ad_account: ad_account, asset_type: "video", asset_id: "v3", thumbnail_url: nil)
      create(:ad_creative, ad_account: ad_account, asset_type: "video", asset_id: "v4", thumbnail_url: nil)
      call = 0
      allow(graph).to receive(:get_object) do
        call += 1
        raise Koala::Facebook::ClientError.new(400, "gone") if call == 1
        { "picture" => "https://x/ok.jpg" }
      end

      expect { service.sync_creative_assets }.not_to raise_error
      expect(call).to eq(2)
    end
  end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/services/meta_ads_service_spec.rb -e "#sync_creative_assets"`
Expected: FAIL — `undefined method 'sync_creative_assets'`.

- [ ] **Step 3: Implement `sync_creative_assets`**

Add to the public section of `app/services/meta_ads_service.rb`:

```ruby
  def sync_creative_assets
    @ad_account.ad_creatives.video.where(thumbnail_url: nil).find_each do |creative|
      data = @graph.get_object(creative.asset_id, fields: "title,length,thumbnails,picture")
      next if data.blank?

      creative.name = data["title"] if data["title"].present?
      creative.duration_seconds = data["length"].to_f.floor if data["length"].present?
      creative.thumbnail_url = data["picture"] if data["picture"].present?
      creative.save!
    rescue Koala::Facebook::ClientError, Koala::Facebook::APIError => e
      Rails.logger.error("[SyncCreativeAssets] video=#{creative.asset_id}: #{e.message}")
    end
  end
```

- [ ] **Step 4: Run the specs to verify they pass**

Run: `bundle exec rspec spec/services/meta_ads_service_spec.rb -e "#sync_creative_assets"`
Expected: PASS (5 examples).

- [ ] **Step 5: Commit**

```bash
bin/rubocop -a
git add app/services/meta_ads_service.rb spec/services/meta_ads_service_spec.rb
git commit -m "feat(ads): backfill creative thumbnails and durations"
```

---

### Task 8: `anchor_state` and `batch_aggregated_metrics`

**Files:**
- Modify: `app/models/ad_creative.rb`
- Test: `spec/models/ad_creative_spec.rb`

**Interfaces:**
- Consumes: Task 1 models.
- Produces: `AdCreative#anchor_state(window_days)` returning one of `:no_spend, :unsynced, :truncated, :insufficient, :ok`; `AdCreative.batch_aggregated_metrics(creative_ids, date_range)` returning `{ creative_id => AdCreative::CreativeMetrics }`; `CreativeMetrics` responding to `two_sec_rate, p50_rate, p75_rate, link_ctr, d1_spend, d1_purchases, d3_roas, d5_roas, lifetime_spend, lifetime_roas`.

- [ ] **Step 1: Write the failing specs**

Append to `spec/models/ad_creative_spec.rb`:

```ruby
  describe "#anchor_state" do
    let(:today) { Date.new(2026, 7, 25) }
    let(:account) { create(:ad_account) }

    def creative_with(fsd:, from:, through:)
      account.update_columns(creative_synced_from_date: from, creative_synced_through_date: through)
      create(:ad_creative, ad_account: account, first_spend_date: fsd)
    end

    it "reports no_spend when the creative never spent" do
      creative = creative_with(fsd: nil, from: today - 89, through: today)
      expect(creative.anchor_state(3)).to eq(:no_spend)
    end

    it "reports no_spend even when the account was never synced" do
      creative = creative_with(fsd: nil, from: nil, through: nil)
      expect(creative.anchor_state(3)).to eq(:no_spend)
    end

    it "reports unsynced when a coverage bound is missing" do
      creative = creative_with(fsd: today - 10, from: nil, through: today)
      expect(creative.anchor_state(3)).to eq(:unsynced)
    end

    it "reports truncated when first spend sits on the coverage start" do
      creative = creative_with(fsd: today - 89, from: today - 89, through: today)
      expect(creative.anchor_state(3)).to eq(:truncated)
    end

    it "prefers truncated over insufficient when both hold" do
      creative = creative_with(fsd: today - 89, from: today - 89, through: today - 88)
      expect(creative.anchor_state(3)).to eq(:truncated)
    end

    it "reports insufficient when the window runs past the coverage end" do
      creative = creative_with(fsd: today - 1, from: today - 89, through: today)
      expect(creative.anchor_state(3)).to eq(:insufficient)
    end

    it "reports ok when the window exactly fits the coverage end" do
      creative = creative_with(fsd: today - 2, from: today - 89, through: today)
      expect(creative.anchor_state(3)).to eq(:ok)
    end

    it "never reports insufficient for a one-day window" do
      creative = creative_with(fsd: today, from: today - 89, through: today)
      expect(creative.anchor_state(1)).to eq(:ok)
    end

    it "still guards a one-day window when the invariant is broken" do
      creative = creative_with(fsd: today, from: today - 89, through: today - 1)
      expect(creative.anchor_state(1)).to eq(:insufficient)
    end

    it "skips the length check for the lifetime window" do
      creative = creative_with(fsd: today, from: today - 89, through: today)
      expect(creative.anchor_state(nil)).to eq(:ok)
    end
  end

  describe ".batch_aggregated_metrics" do
    let(:today) { Date.new(2026, 7, 25) }
    let(:account) { create(:ad_account, creative_synced_from_date: today - 89, creative_synced_through_date: today) }
    let(:creative) { create(:ad_creative, ad_account: account, first_spend_date: today - 10) }

    def metric(date, attrs = {})
      unit = @unit ||= create(:ad_unit, ad_account: account, ad_creative: creative)
      create(:ad_unit_daily_metric, { ad_unit: unit, date: date }.merge(attrs))
    end

    it "sums several ad units into one creative" do
      unit_a = create(:ad_unit, ad_account: account, ad_creative: creative)
      unit_b = create(:ad_unit, ad_account: account, ad_creative: creative)
      create(:ad_unit_daily_metric, ad_unit: unit_a, date: today, impressions: 1000, inline_link_clicks: 30)
      create(:ad_unit_daily_metric, ad_unit: unit_b, date: today, impressions: 1000, inline_link_clicks: 10)

      m = described_class.batch_aggregated_metrics([ creative.id ], today..today)[creative.id]

      expect(m.link_ctr).to eq(2.0)
    end

    it "computes completion rates against impressions" do
      metric(today, impressions: 1000, video_continuous_2_sec_watched: 300,
        video_p50_watched: 150, video_p75_watched: 90)

      m = described_class.batch_aggregated_metrics([ creative.id ], today..today)[creative.id]

      expect(m.two_sec_rate).to eq(30.0)
      expect(m.p50_rate).to eq(15.0)
      expect(m.p75_rate).to eq(9.0)
    end

    it "returns zero rather than dividing by zero" do
      metric(today, impressions: 0, clicks: 0, spend: 0, conversion_value: 0)

      m = described_class.batch_aggregated_metrics([ creative.id ], today..today)[creative.id]

      expect(m.two_sec_rate).to eq(0)
      expect(m.link_ctr).to eq(0)
      expect(m.lifetime_roas).to eq(0)
    end

    it "anchors D1 on first_spend_date, not on the selected range" do
      metric(today - 10, spend: 50, purchases: 4)
      metric(today, spend: 999, purchases: 99)

      m = described_class.batch_aggregated_metrics([ creative.id ], today..today)[creative.id]

      expect(m.d1_spend).to eq(50)
      expect(m.d1_purchases).to eq(4)
    end

    it "accumulates D3 across the first three days from the anchor" do
      metric(today - 10, spend: 10, conversion_value: 20)
      metric(today - 9, spend: 10, conversion_value: 30)
      metric(today - 8, spend: 10, conversion_value: 10)
      metric(today - 7, spend: 999, conversion_value: 999)

      m = described_class.batch_aggregated_metrics([ creative.id ], today..today)[creative.id]

      expect(m.d3_roas).to eq(2.0)
    end

    it "bounds the lifetime sum by the coverage interval" do
      metric(today - 10, spend: 100, conversion_value: 200)
      # A row outside coverage simulates a broken invariant; it must be ignored.
      account.update_column(:creative_synced_from_date, today - 5)

      m = described_class.batch_aggregated_metrics([ creative.id ], today..today)[creative.id]

      expect(m.lifetime_spend).to eq(0)
    end

    it "returns a zeroed struct for a creative with no rows" do
      other = create(:ad_creative, ad_account: account)

      m = described_class.batch_aggregated_metrics([ other.id ], today..today)[other.id]

      expect(m.lifetime_spend).to eq(0)
      expect(m.two_sec_rate).to eq(0)
    end

    it "excludes ad units flagged multi_asset" do
      excluded = create(:ad_unit, ad_account: account, ad_creative: creative, multi_asset: true)
      create(:ad_unit_daily_metric, ad_unit: excluded, date: today, impressions: 5000)
      metric(today, impressions: 1000)

      m = described_class.batch_aggregated_metrics([ creative.id ], today..today)[creative.id]

      expect(m.impressions).to eq(1000)
    end
  end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/models/ad_creative_spec.rb`
Expected: FAIL — `undefined method 'anchor_state'`.

- [ ] **Step 3: Implement `anchor_state`**

Add to `app/models/ad_creative.rb`:

```ruby
  # Ordered and total. The order is load-bearing: the conditions overlap, and a
  # truncated anchor makes a number WRONG rather than merely incomplete, so it
  # must outrank :insufficient (spec §6.3).
  #
  # window_days nil means the lifetime window, which has no length to check.
  def anchor_state(window_days)
    return :no_spend if first_spend_date.nil?

    from = ad_account.creative_synced_from_date
    through = ad_account.creative_synced_through_date
    return :unsynced if from.nil? || through.nil?
    return :truncated if first_spend_date <= from

    # Unreachable for window_days == 1 while the coverage invariant holds. Kept
    # deliberately: it is the only guard if the invariant is ever broken.
    return :insufficient if window_days.present? && first_spend_date + (window_days - 1) > through

    :ok
  end
```

- [ ] **Step 4: Implement `batch_aggregated_metrics` and `CreativeMetrics`**

Add to `app/models/ad_creative.rb`:

```ruby
  CreativeMetrics = Struct.new(
    :impressions, :inline_link_clicks,
    :video_continuous_2_sec_watched, :video_p50_watched, :video_p75_watched,
    :d1_spend, :d1_purchases,
    :d3_spend, :d3_value, :d5_spend, :d5_value,
    :lifetime_spend, :lifetime_value
  ) do
    def two_sec_rate = percentage(video_continuous_2_sec_watched, impressions)
    def p50_rate = percentage(video_p50_watched, impressions)
    def p75_rate = percentage(video_p75_watched, impressions)
    def link_ctr = percentage(inline_link_clicks, impressions)
    def d3_roas = ratio(d3_value, d3_spend)
    def d5_roas = ratio(d5_value, d5_spend)
    def lifetime_roas = ratio(lifetime_value, lifetime_spend)

    private

    def percentage(numerator, denominator)
      return 0 if denominator.to_i.zero?

      (numerator.to_f / denominator * 100).round(2)
    end

    def ratio(numerator, denominator)
      return 0 if denominator.to_f.zero?

      (numerator.to_f / denominator.to_f).round(2)
    end
  end

  def self.batch_aggregated_metrics(creative_ids, date_range)
    ids = Array(creative_ids)
    return {} if ids.empty?

    range = range_totals(ids, date_range)
    anchored = { 1 => anchor_totals(ids, 1), 3 => anchor_totals(ids, 3), 5 => anchor_totals(ids, 5) }
    lifetime = lifetime_totals(ids)

    ids.index_with do |id|
      r = range[id] || {}
      d1 = anchored[1][id] || {}
      d3 = anchored[3][id] || {}
      d5 = anchored[5][id] || {}
      lt = lifetime[id] || {}

      CreativeMetrics.new(
        r[:impressions].to_i, r[:inline_link_clicks].to_i,
        r[:two_sec].to_i, r[:p50].to_i, r[:p75].to_i,
        d1[:spend].to_f, d1[:purchases].to_i,
        d3[:spend].to_f, d3[:value].to_f,
        d5[:spend].to_f, d5[:value].to_f,
        lt[:spend].to_f, lt[:value].to_f
      )
    end
  end

  # Only attributable units count: multi_asset ads cannot be assigned to one
  # creative, so their spend must never land in a creative's numbers.
  def self.metrics_join
    joins("INNER JOIN ad_units ON ad_units.ad_creative_id = ad_creatives.id")
      .joins("INNER JOIN ad_unit_daily_metrics ON ad_unit_daily_metrics.ad_unit_id = ad_units.id")
      .where(ad_units: { multi_asset: false })
  end
  private_class_method :metrics_join

  def self.range_totals(ids, date_range)
    metrics_join
      .where(id: ids, ad_unit_daily_metrics: { date: date_range })
      .group("ad_creatives.id")
      .pluck(
        Arel.sql("ad_creatives.id"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.impressions), 0)"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.inline_link_clicks), 0)"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.video_continuous_2_sec_watched), 0)"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.video_p50_watched), 0)"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.video_p75_watched), 0)")
      )
      .to_h { |row| [ row[0], { impressions: row[1], inline_link_clicks: row[2], two_sec: row[3], p50: row[4], p75: row[5] } ] }
  end
  private_class_method :range_totals

  def self.anchor_totals(ids, window_days)
    metrics_join
      .where(id: ids)
      .where("ad_unit_daily_metrics.date BETWEEN ad_creatives.first_spend_date " \
             "AND ad_creatives.first_spend_date + ?", window_days - 1)
      .group("ad_creatives.id")
      .pluck(
        Arel.sql("ad_creatives.id"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.spend), 0)"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.conversion_value), 0)"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.purchases), 0)")
      )
      .to_h { |row| [ row[0], { spend: row[1], value: row[2], purchases: row[3] } ] }
  end
  private_class_method :anchor_totals

  # Explicitly bounded by the coverage interval. Under the invariant this equals
  # "all synced days", but carrying the bound means a broken invariant can only
  # under-count, never silently inflate a lifetime figure (spec §6.3).
  def self.lifetime_totals(ids)
    metrics_join
      .joins("INNER JOIN ad_accounts ON ad_accounts.id = ad_creatives.ad_account_id")
      .where(id: ids)
      .where("ad_unit_daily_metrics.date BETWEEN ad_accounts.creative_synced_from_date " \
             "AND ad_accounts.creative_synced_through_date")
      .group("ad_creatives.id")
      .pluck(
        Arel.sql("ad_creatives.id"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.spend), 0)"),
        Arel.sql("COALESCE(SUM(ad_unit_daily_metrics.conversion_value), 0)")
      )
      .to_h { |row| [ row[0], { spend: row[1], value: row[2] } ] }
  end
  private_class_method :lifetime_totals
```

- [ ] **Step 5: Run the specs to verify they pass**

Run: `bundle exec rspec spec/models/ad_creative_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
bin/rubocop -a
git add app/models/ad_creative.rb spec/models/ad_creative_spec.rb
git commit -m "feat(ads): creative anchor states and aggregated metrics"
```

---

### Task 9: Controller, routes, permission, i18n, navigation

**Files:**
- Create: `app/controllers/ad_creatives_controller.rb`
- Modify: `config/routes.rb`, `app/models/membership.rb`, `app/controllers/admin_controller.rb`, `app/views/shared/_sidebar.html.erb`, `config/locales/en.yml`, `config/locales/zh-TW.yml`, `config/locales/zh-CN.yml`
- Test: `spec/requests/ad_creatives_spec.rb`

**Interfaces:**
- Consumes: `AdCreative.batch_aggregated_metrics`, `#anchor_state` (Task 8); `BackfillAdCreativesJob` (Task 5).
- Produces: `ad_creatives_path`, `sync_ad_creatives_path`; instance variables `@creatives`, `@creative_metrics`, `@ad_accounts`, `@selected_account`, `@from_date`, `@to_date`, `@sort_column`, `@sort_direction`.

- [ ] **Step 1: Write the failing request specs**

```ruby
# spec/requests/ad_creatives_spec.rb
require "rails_helper"

RSpec.describe "AdCreatives", type: :request do
  let(:user) { create(:user) }
  let(:store) { create(:shopify_store, user: user) }
  let(:ad_account) { create(:ad_account, user: user, shopify_store: store) }

  describe "GET /ad_creatives" do
    it "returns success for an authenticated user" do
      sign_in user
      get ad_creatives_path
      expect(response).to have_http_status(:success)
    end

    it "redirects an unauthenticated user" do
      get ad_creatives_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "shows the empty state when there are no creatives" do
      sign_in user
      get ad_creatives_path
      expect(response.body).to include("No ad creatives found")
    end

    it "lists creatives with metrics" do
      creative = create(:ad_creative, ad_account: ad_account, name: "Toy Duck Demo v1")
      unit = create(:ad_unit, ad_account: ad_account, ad_creative: creative)
      create(:ad_unit_daily_metric, ad_unit: unit, date: Date.current, impressions: 12_345)

      sign_in user
      get ad_creatives_path, params: { store_id: store.id }

      expect(response.body).to include("Toy Duck Demo v1")
      expect(response.body).to include("12,345")
    end

    it "does not show creatives belonging to another user" do
      other_account = create(:ad_account, user: create(:user))
      create(:ad_creative, ad_account: other_account, name: "Competitor Hook Alpha")

      sign_in user
      get ad_creatives_path

      expect(response.body).not_to include("Competitor Hook Alpha")
    end

    it "filters by ad account" do
      keep = create(:ad_creative, ad_account: ad_account, name: "Kept Creative Alpha")
      other = create(:ad_account, user: user, account_name: "Second")
      create(:ad_creative, ad_account: other, name: "Filtered Creative Beta")

      sign_in user
      get ad_creatives_path, params: { ad_account_id: ad_account.id }

      expect(response.body).to include(keep.name)
      expect(response.body).not_to include("Filtered Creative Beta")
    end

    it "falls back to the default range for an unparseable date" do
      sign_in user
      get ad_creatives_path, params: { from_date: "not-a-date" }
      expect(response).to have_http_status(:success)
    end

    it "rejects a sort column that is not allow-listed" do
      sign_in user
      get ad_creatives_path, params: { sort_column: "spend; DROP TABLE users" }
      expect(response).to have_http_status(:success)
    end

    it "excludes creatives whose only ad unit is multi_asset" do
      creative = create(:ad_creative, ad_account: ad_account, name: "Advantage Bundle Gamma")
      create(:ad_unit, ad_account: ad_account, ad_creative: creative, multi_asset: true)

      sign_in user
      get ad_creatives_path

      expect(response.body).not_to include("Advantage Bundle Gamma")
    end
  end

  describe "POST /ad_creatives/sync" do
    it "enqueues a backfill for each visible account" do
      ad_account
      sign_in user

      expect {
        post sync_ad_creatives_path
      }.to have_enqueued_job(BackfillAdCreativesJob).with(ad_account_id: ad_account.id, days: 90)
    end

    it "redirects back with a notice" do
      ad_account
      sign_in user

      post sync_ad_creatives_path

      expect(response).to redirect_to(ad_creatives_path)
      expect(flash[:notice]).to be_present
    end

    it "does not enqueue twice on a rapid second click" do
      ad_account
      sign_in user
      post sync_ad_creatives_path

      expect { post sync_ad_creatives_path }.not_to have_enqueued_job(BackfillAdCreativesJob)
    end
  end
end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/requests/ad_creatives_spec.rb`
Expected: FAIL — `undefined local variable or method 'ad_creatives_path'`.

- [ ] **Step 3: Add the route**

In `config/routes.rb`, directly below the `resources :ad_campaigns` block:

```ruby
    resources :ad_creatives, only: [ :index ] do
      post :sync, on: :collection
    end
```

- [ ] **Step 4: Grant the permission and add the store switcher**

In `app/models/membership.rb`, change the first line of `AVAILABLE_PERMISSIONS` to:

```ruby
    orders shipments tickets ad_campaigns ad_creatives
```

In `app/controllers/admin_controller.rb`, change `STORE_SWITCHER_CONTROLLERS` to:

```ruby
  STORE_SWITCHER_CONTROLLERS = %w[dashboard orders shipments tickets ad_campaigns ad_creatives packages].freeze
```

- [ ] **Step 5: Write the controller**

```ruby
# app/controllers/ad_creatives_controller.rb
class AdCreativesController < AdminController
  SORTABLE_COLUMNS = %w[
    two_sec_rate p50_rate p75_rate link_ctr
    d1_spend d1_purchases d3_roas d5_roas
    lifetime_spend lifetime_roas
  ].freeze

  BACKFILL_DAYS = 90

  def sync
    visible_ad_accounts.each do |account|
      next unless account.claim_backfill_slot!(manual: true)

      BackfillAdCreativesJob.perform_later(ad_account_id: account.id, days: BACKFILL_DAYS)
    end

    redirect_to ad_creatives_path, notice: t("ad_creatives.sync_enqueued")
  end

  def index
    view_scope = selected_view_group || current_company
    base_ad_accounts = view_scope.respond_to?(:ad_accounts) ? view_scope.ad_accounts : visible_ad_accounts

    @selected_store = current_shopify_store

    @ad_accounts = if @selected_store
      base_ad_accounts.where(shopify_store: @selected_store).order(:account_name)
    else
      base_ad_accounts.order(:account_name)
    end

    @selected_account = if params[:ad_account_id].present? && params[:ad_account_id] != "all"
      @ad_accounts.find_by(id: params[:ad_account_id])
    end

    accounts = @selected_account ? [ @selected_account ] : @ad_accounts

    load_date_range
    @sort_column = SORTABLE_COLUMNS.include?(params[:sort_column]) ? params[:sort_column] : "lifetime_spend"
    @sort_direction = params[:sort_direction] == "asc" ? "asc" : "desc"

    creatives = AdCreative
      .where(ad_account: accounts)
      .where(id: AdUnit.attributable.select(:ad_creative_id))
      .includes(:ad_account)

    @creative_metrics = AdCreative.batch_aggregated_metrics(creatives.pluck(:id), @from_date..@to_date)
    @creatives = sort_creatives(creatives.to_a)
  end

  private

  def load_date_range
    @from_date = params[:from_date].present? ? Date.parse(params[:from_date]) : 7.days.ago.to_date
    @to_date = params[:to_date].present? ? Date.parse(params[:to_date]) : Date.current
  rescue Date::Error
    @from_date = 7.days.ago.to_date
    @to_date = Date.current
  end

  def sort_creatives(creatives)
    direction = @sort_direction == "asc" ? 1 : -1

    creatives.sort_by do |creative|
      metrics = @creative_metrics[creative.id]
      [ direction * metrics.public_send(@sort_column).to_f, creative.name.to_s ]
    end
  end
end
```

- [ ] **Step 6: Add the i18n keys**

Add this block to `config/locales/en.yml` at the same indent level as the existing `ad_campaigns:` key:

```yaml
  ad_creatives:
    title: "Ad Creatives"
    empty: "No ad creatives found."
    sync_ads: "Sync Creative Data"
    sync_enqueued: "Creative data sync has been enqueued."
    all_accounts: "All Ad Accounts"
    filter: "Filter"
    from_date: "From"
    to_date: "To"
    not_applicable: "—"
    groups:
      creative: "Creative"
      engagement: "Engagement (selected range)"
      cold_start: "Cold Start (from first spend)"
      lifetime: "Lifetime (synced range)"
    columns:
      name: "Creative"
      two_sec_rate: "2s Play %"
      p50_rate: "50% Watched %"
      p75_rate: "75% Watched %"
      link_ctr: "CTR (Link-Click)"
      d1_spend: "D1 Spend"
      d1_purchases: "D1 Conversions"
      d3_roas: "D3 ROAS"
      d5_roas: "D5 ROAS"
      lifetime_spend: "Lifetime Spend"
      lifetime_roas: "Lifetime ROAS"
      platform: "Platform"
    states:
      truncated_hint: "First spend predates the synced range — cold-start figures are unreliable."
      unsynced_hint: "This account has not been synced yet."
```

Add the same key structure to `config/locales/zh-TW.yml`:

```yaml
  ad_creatives:
    title: "廣告素材"
    empty: "找不到廣告素材。"
    sync_ads: "同步素材資料"
    sync_enqueued: "素材資料同步已排入佇列。"
    all_accounts: "全部廣告帳號"
    filter: "篩選"
    from_date: "起始"
    to_date: "結束"
    not_applicable: "—"
    groups:
      creative: "素材"
      engagement: "互動(選定區間)"
      cold_start: "冷啟動(自首次投放起算)"
      lifetime: "生命週期(已同步範圍)"
    columns:
      name: "素材"
      two_sec_rate: "2秒播放率"
      p50_rate: "50%完播率"
      p75_rate: "75%完播率"
      link_ctr: "CTR(連結點擊)"
      d1_spend: "第1天花費"
      d1_purchases: "第1天轉化數"
      d3_roas: "D3累計ROAS"
      d5_roas: "D5累計ROAS"
      lifetime_spend: "生命週期總花費"
      lifetime_roas: "生命週期ROAS"
      platform: "投放平台"
    states:
      truncated_hint: "首次投放早於已同步範圍,冷啟動數字不可信。"
      unsynced_hint: "此帳號尚未同步。"
```

Add the same key structure to `config/locales/zh-CN.yml`, using Simplified Chinese equivalents of the zh-TW strings above (e.g. `title: "广告素材"`, `empty: "找不到广告素材。"`, `two_sec_rate: "2秒播放率"`, `p50_rate: "50%完播率"`, `lifetime_spend: "生命周期总花费"`).

In all three locale files, also add `ad_creatives:` to the `nav:` block next to the existing `ad_campaigns:` entry — `"Ad Creatives"` / `"廣告素材"` / `"广告素材"`.

- [ ] **Step 7: Add the sidebar link**

In `app/views/shared/_sidebar.html.erb`, directly after the `ad_campaigns` block that ends around line 273:

```erb
    <% if current_membership&.has_permission?("ad_creatives") %>
      <%= link_to ad_creatives_path, data: { action: "click->sidebar#close" },
          class: "flex items-center gap-3 px-3 py-2 text-sm font-medium rounded-md #{current_page?(ad_creatives_path) ? 'bg-gray-100 text-gray-900' : 'text-gray-600 hover:bg-gray-50 hover:text-gray-900'}" do %>
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z" />
        </svg>
        <%= t("nav.ad_creatives") %>
      <% end %>
    <% end %>
```

- [ ] **Step 8: Run the specs (the view arrives in Task 10, so expect a template error)**

Run: `bundle exec rspec spec/requests/ad_creatives_spec.rb`
Expected: FAIL with `ActionView::MissingTemplate` for `index`, and PASS for the three `POST /ad_creatives/sync` examples. That is the correct state at this point.

- [ ] **Step 9: Commit**

```bash
bin/rubocop -a
git add config/routes.rb config/locales/ app/controllers/ app/models/membership.rb app/views/shared/_sidebar.html.erb spec/requests/ad_creatives_spec.rb
git commit -m "feat(ads): ad creatives controller, route, permission and i18n"
```

---

### Task 10: View template and system specs

**Files:**
- Create: `app/views/ad_creatives/index.html.erb`
- Test: `spec/system/ad_creatives_spec.rb`

**Interfaces:**
- Consumes: everything from Tasks 8 and 9.
- Produces: the rendered table. No new Ruby interfaces.

- [ ] **Step 1: Write the failing system specs**

```ruby
# spec/system/ad_creatives_spec.rb
require "rails_helper"

RSpec.describe "Ad Creatives", type: :system do
  let!(:user) { create(:user) }
  let!(:store) { create(:shopify_store, user: user) }
  let!(:ad_account) do
    create(:ad_account, user: user, shopify_store: store, account_name: "Meta Ads",
      creative_synced_from_date: Date.current - 89, creative_synced_through_date: Date.current)
  end

  def creative_with_metrics(name:, first_spend_date:, **metric_attrs)
    creative = create(:ad_creative, ad_account: ad_account, name: name, first_spend_date: first_spend_date)
    unit = create(:ad_unit, ad_account: ad_account, ad_creative: creative)
    create(:ad_unit_daily_metric, { ad_unit: unit, date: Date.current }.merge(metric_attrs))
    creative
  end

  it "shows the empty state when there are no creatives" do
    sign_in_as(user)
    click_link "Ad Creatives"
    expect(page).to have_text("No ad creatives found")
  end

  it "shows creatives with engagement metrics" do
    creative_with_metrics(
      name: "Toy Duck Demo v1", first_spend_date: Date.current - 10,
      impressions: 10_000, inline_link_clicks: 300,
      video_continuous_2_sec_watched: 3_700, video_p50_watched: 1_200, video_p75_watched: 700
    )

    sign_in_as(user)
    click_link "Ad Creatives"

    expect(page).to have_text("Toy Duck Demo v1")
    expect(page).to have_text("Meta Ads")
    expect(page).to have_text("37.0%")
    expect(page).to have_text("12.0%")
    expect(page).to have_text("3.0%")
  end

  it "shows a dash for completion columns on an image creative" do
    creative = create(:ad_creative, ad_account: ad_account, asset_type: "image",
      asset_id: "hash1", name: "Static Banner", first_spend_date: Date.current - 10)
    unit = create(:ad_unit, ad_account: ad_account, ad_creative: creative)
    create(:ad_unit_daily_metric, ad_unit: unit, date: Date.current,
      impressions: 5_000, video_continuous_2_sec_watched: 0,
      video_p50_watched: 0, video_p75_watched: 0)

    sign_in_as(user)
    click_link "Ad Creatives"

    expect(page).to have_text("Static Banner")
    within("tr", text: "Static Banner") { expect(page).to have_text("—") }
  end

  it "marks a creative whose first spend predates the synced range" do
    creative_with_metrics(name: "Old Hook", first_spend_date: Date.current - 89, spend: 40)

    sign_in_as(user)
    click_link "Ad Creatives"

    within("tr", text: "Old Hook") { expect(page).to have_css("[data-anchor-state='truncated']") }
  end

  it "sorts by a chosen column" do
    creative_with_metrics(name: "Low Spender", first_spend_date: Date.current - 10, spend: 10)
    creative_with_metrics(name: "High Spender", first_spend_date: Date.current - 10, spend: 900)

    sign_in_as(user)
    click_link "Ad Creatives"
    click_link "Lifetime Spend"

    rows = page.all("tbody tr").map(&:text)
    expect(rows.first).to include("High Spender")
  end

  it "filters by date range" do
    creative_with_metrics(name: "In Range", first_spend_date: Date.current - 10, impressions: 4_242)

    sign_in_as(user)
    click_link "Ad Creatives"
    fill_in "from_date", with: (Date.current - 1).to_s
    fill_in "to_date", with: Date.current.to_s
    click_button "Filter"

    expect(page).to have_text("4,242")
  end
end
```

- [ ] **Step 2: Run the specs to verify they fail**

Run: `bundle exec rspec spec/system/ad_creatives_spec.rb`
Expected: FAIL — `ActionView::MissingTemplate`.

Note: if chromedriver is a major version ahead of the installed Chrome, prepend the selenium-manager download to `PATH`: `export PATH=/tmp/chromedriver-linux64:$PATH`.

- [ ] **Step 3: Write the view**

```erb
<%# app/views/ad_creatives/index.html.erb %>
<div class="px-4 sm:px-6 lg:px-8 py-6">
  <div class="flex items-center justify-between mb-6">
    <h1 class="text-2xl font-semibold text-gray-900"><%= t("ad_creatives.title") %></h1>
    <%= button_to t("ad_creatives.sync_ads"), sync_ad_creatives_path, method: :post,
        class: "px-4 py-2 text-sm font-medium text-white bg-gray-900 rounded-md hover:bg-gray-700" %>
  </div>

  <%= form_with url: ad_creatives_path, method: :get, class: "flex flex-wrap items-end gap-3 mb-6" do %>
    <div>
      <label class="block text-xs font-medium text-gray-500 mb-1"><%= t("ad_creatives.from_date") %></label>
      <%= date_field_tag :from_date, @from_date, class: "rounded-md border-gray-300 text-sm" %>
    </div>
    <div>
      <label class="block text-xs font-medium text-gray-500 mb-1"><%= t("ad_creatives.to_date") %></label>
      <%= date_field_tag :to_date, @to_date, class: "rounded-md border-gray-300 text-sm" %>
    </div>
    <div>
      <%= select_tag :ad_account_id,
          options_from_collection_for_select(@ad_accounts, :id, :account_name, @selected_account&.id),
          include_blank: t("ad_creatives.all_accounts"), class: "rounded-md border-gray-300 text-sm" %>
    </div>
    <%= submit_tag t("ad_creatives.filter"),
        class: "px-4 py-2 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50" %>
  <% end %>

  <% if @creatives.empty? %>
    <p class="text-sm text-gray-500"><%= t("ad_creatives.empty") %></p>
  <% else %>
    <div class="overflow-x-auto bg-white border border-gray-200 rounded-lg">
      <table class="min-w-full divide-y divide-gray-200 text-sm">
        <thead class="bg-gray-50">
          <%# Three different time bases share this table; the group header row keeps them apart. %>
          <tr class="text-xs uppercase tracking-wide text-gray-500">
            <th class="px-3 py-2 text-left" colspan="2"><%= t("ad_creatives.groups.creative") %></th>
            <th class="px-3 py-2 text-center border-l border-gray-200" colspan="4"><%= t("ad_creatives.groups.engagement") %></th>
            <th class="px-3 py-2 text-center border-l border-gray-200" colspan="4"><%= t("ad_creatives.groups.cold_start") %></th>
            <th class="px-3 py-2 text-center border-l border-gray-200" colspan="2"><%= t("ad_creatives.groups.lifetime") %></th>
          </tr>
          <tr class="text-xs font-medium text-gray-500">
            <th class="px-3 py-2 text-left"><%= t("ad_creatives.columns.name") %></th>
            <th class="px-3 py-2 text-left"><%= t("ad_creatives.columns.platform") %></th>
            <% AdCreativesController::SORTABLE_COLUMNS.each_with_index do |column, index| %>
              <th class="px-3 py-2 text-right <%= 'border-l border-gray-200' if [0, 4, 8].include?(index) %>">
                <%= link_to t("ad_creatives.columns.#{column}"),
                    ad_creatives_path(request.query_parameters.merge(
                      sort_column: column,
                      sort_direction: (@sort_column == column && @sort_direction == "desc") ? "asc" : "desc"
                    )), class: "hover:text-gray-900" %>
              </th>
            <% end %>
          </tr>
        </thead>
        <tbody class="divide-y divide-gray-100">
          <% @creatives.each do |creative| %>
            <% metrics = @creative_metrics[creative.id] %>
            <% video = creative.asset_type == "video" %>
            <tr>
              <td class="px-3 py-2">
                <div class="flex items-center gap-2">
                  <% if creative.thumbnail_url.present? %>
                    <%= image_tag creative.thumbnail_url, class: "w-10 h-10 rounded object-cover", loading: "lazy" %>
                  <% end %>
                  <span class="font-medium text-gray-900"><%= creative.name %></span>
                </div>
              </td>
              <td class="px-3 py-2 text-gray-500"><%= creative.ad_account.platform %></td>

              <%# Engagement — selected range. Video-only columns dash out for images. %>
              <td class="px-3 py-2 text-right border-l border-gray-100"><%= video ? number_to_percentage(metrics.two_sec_rate, precision: 1) : t("ad_creatives.not_applicable") %></td>
              <td class="px-3 py-2 text-right"><%= video ? number_to_percentage(metrics.p50_rate, precision: 1) : t("ad_creatives.not_applicable") %></td>
              <td class="px-3 py-2 text-right"><%= video ? number_to_percentage(metrics.p75_rate, precision: 1) : t("ad_creatives.not_applicable") %></td>
              <td class="px-3 py-2 text-right"><%= number_to_percentage(metrics.link_ctr, precision: 2) %></td>

              <%# Cold start — anchored on first_spend_date, each column carries its own window. %>
              <%= render "anchor_cell", creative: creative, window: 1, value: number_to_currency(metrics.d1_spend), first: true %>
              <%= render "anchor_cell", creative: creative, window: 1, value: number_with_delimiter(metrics.d1_purchases), first: false %>
              <%= render "anchor_cell", creative: creative, window: 3, value: metrics.d3_roas, first: false %>
              <%= render "anchor_cell", creative: creative, window: 5, value: metrics.d5_roas, first: false %>

              <%# Lifetime — bounded by the account's synced coverage. %>
              <%= render "anchor_cell", creative: creative, window: nil, value: number_to_currency(metrics.lifetime_spend), first: true %>
              <%= render "anchor_cell", creative: creative, window: nil, value: metrics.lifetime_roas, first: false %>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
  <% end %>
</div>
```

```erb
<%# app/views/ad_creatives/_anchor_cell.html.erb %>
<%# locals: (creative:, window:, value:, first:) %>
<% state = creative.anchor_state(window) %>
<td class="px-3 py-2 text-right <%= 'border-l border-gray-100' if first %>" data-anchor-state="<%= state %>">
  <% case state %>
  <% when :no_spend %>
    <span class="text-gray-300"><%= t("ad_creatives.not_applicable") %></span>
  <% when :unsynced %>
    <span class="text-gray-300" title="<%= t("ad_creatives.states.unsynced_hint") %>">·</span>
  <% when :truncated %>
    <span class="text-amber-500" title="<%= t("ad_creatives.states.truncated_hint") %>">⚠</span>
  <% when :insufficient %>
    <span class="text-gray-300"></span>
  <% else %>
    <%= value %>
  <% end %>
</td>
```

Note the strict-locals magic comment must have nothing after the closing paren, or the partial will not compile.

- [ ] **Step 4: Run the request and system specs**

Run:
```bash
bundle exec rspec spec/requests/ad_creatives_spec.rb spec/system/ad_creatives_spec.rb
```
Expected: PASS.

- [ ] **Step 5: Run the whole suite and the linters**

Run:
```bash
bundle exec rspec
bin/rubocop
bin/brakeman --no-pager
```
Expected: all green. Investigate any pre-existing flake in `spec/system` (the `shopify_stores` connect and `shipping_reminder` toggle specs are known timing-flaky) by re-running before assuming a real break.

- [ ] **Step 6: Commit**

```bash
git add app/views/ad_creatives/ spec/system/ad_creatives_spec.rb
git commit -m "feat(ads): ad creatives table view with anchor state cells"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §2 column definitions | 8, 10 |
| §2.1 2-second substitution | 3 (field list), 8 (`two_sec_rate`) |
| §2.2 impressions denominator | 8 |
| §2.3 list-valued video fields | 3 |
| §2.4 ad account timezone | 1 (`today_in_zone`), 4, 6 |
| §2.5 account attribution setting | 3 |
| §3 no `video_asset` breakdown | architecture, no task needed |
| §4.0 coverage + throttle columns | 1 |
| §4.1–4.3 tables and indexes | 1 |
| §4.4 associations | 1 |
| §4.5 multi-asset exclusion | 2, 8 |
| §5.1 `sync_ad_units`, resolution order, pagination | 2 |
| §5.1 `fetch_ad_insights` | 3 |
| §5.1 `sync_creative_assets` | 7 |
| §5.2 both jobs and three triggers | 5, 6 |
| §5.3 lookback floor | 6 |
| §5.4 rate limit / segment abort | 4 |
| §5.5 `first_spend_date` | 4 |
| §5.6 invariant, modes A/B, transactions | 4 |
| §5.6 rolling eligibility + self-healing | 6 |
| §5.6 throttle + atomic claim | 5 |
| §6.1 route, controller, scoping | 9 |
| §6.2 `batch_aggregated_metrics` | 8 |
| §6.3 `anchor_state`, lifetime bound, display | 8, 10 |
| §6.4 OAuth scope unchanged | no task needed — verified, `ads_management,ads_read` already requested |
| §7 test plan | every task |

Mode C (§5.6) is intentionally unimplemented and documented as out of scope in Global Constraints.

**Type consistency:** `CreativeMetrics` accessor names used in Task 10 and in `AdCreativesController::SORTABLE_COLUMNS` match the Struct defined in Task 8 (`two_sec_rate`, `p50_rate`, `p75_rate`, `link_ctr`, `d1_spend`, `d1_purchases`, `d3_roas`, `d5_roas`, `lifetime_spend`, `lifetime_roas`). `anchor_state` returns the five symbols consumed by `_anchor_cell.html.erb`. `fetch_ad_insights` row keys match the columns assigned in `persist_segment` via `row.except(:ad_id, :date)`, which maps exactly onto the `ad_unit_daily_metrics` columns created in Task 1.

**Note for Task 8 reviewers:** `CreativeMetrics` exposes `impressions` as a Struct member, which the Task 8 spec `"excludes ad units flagged multi_asset"` asserts on directly.
