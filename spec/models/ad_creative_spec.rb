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
end
