require "rails_helper"

RSpec.describe GoogleAdsService do
  # Stands in for GoogleAdsApi: records the query and returns canned rows —
  # account totals for `FROM customer`, the campaign list for the unsegmented
  # campaign search, campaign days for the segmented one.
  class FakeGoogleAdsApi
    attr_reader :queries

    def initialize(rows = [], error: nil, campaigns: [], campaign_days: [])
      @rows = rows
      @campaigns = campaigns
      @campaign_days = campaign_days
      @error = error
      @queries = []
    end

    def search(customer_id, query)
      raise @error if @error

      @queries << [ customer_id, query ]
      if query.include?("FROM customer") then @rows
      elsif query.include?("segments.date") then @campaign_days
      else @campaigns
      end
    end
  end

  let(:account) { create(:ad_account, :google, account_id: "5228314437") }

  def row(date, cost_micros:, clicks: 10, impressions: 100, conversions: 1.6, value: 80.456)
    { "segments" => { "date" => date },
      "metrics" => { "costMicros" => cost_micros.to_s, "clicks" => clicks.to_s, "impressions" => impressions.to_s,
                     "conversions" => conversions, "conversionsValue" => value } }
  end

  it "writes one daily metric per reported day, converting micros and rounding conversions" do
    api = FakeGoogleAdsApi.new([ row("2026-10-01", cost_micros: 12_345_678), row("2026-10-02", cost_micros: 0, conversions: 0, value: 0) ])

    described_class.new(account, api: api).sync_date_range(Date.new(2026, 10, 1), Date.new(2026, 10, 2))

    metric = account.ad_daily_metrics.find_by!(date: "2026-10-01")
    expect(metric.spend).to eq(BigDecimal("12.35"))
    expect(metric.clicks).to eq(10)
    expect(metric.impressions).to eq(100)
    expect(metric.conversions).to eq(2)
    expect(metric.conversion_value).to eq(BigDecimal("80.46"))
    expect(account.ad_daily_metrics.count).to eq(2)

    customer_id, query = api.queries.first
    expect(customer_id).to eq("5228314437")
    expect(query).to include("BETWEEN '2026-10-01' AND '2026-10-02'")
  end

  it "overwrites a day with the restated figures" do
    create(:ad_daily_metric, ad_account: account, date: "2026-10-01", spend: 5, conversions: 0)

    described_class.new(account, api: FakeGoogleAdsApi.new([ row("2026-10-01", cost_micros: 9_000_000) ]))
                   .sync_date_range(Date.new(2026, 10, 1), Date.new(2026, 10, 1))

    expect(account.ad_daily_metrics.find_by!(date: "2026-10-01").spend).to eq(9)
    expect(account.ad_daily_metrics.count).to eq(1)
  end

  it "zeroes a day in range that the API no longer reports, leaving days outside the range alone" do
    create(:ad_daily_metric, ad_account: account, date: "2026-10-02", spend: 7, clicks: 3)
    create(:ad_daily_metric, ad_account: account, date: "2026-09-01", spend: 4)

    described_class.new(account, api: FakeGoogleAdsApi.new([ row("2026-10-01", cost_micros: 1_000_000) ]))
                   .sync_date_range(Date.new(2026, 10, 1), Date.new(2026, 10, 2))

    expect(account.ad_daily_metrics.find_by!(date: "2026-10-02")).to have_attributes(spend: 0, clicks: 0)
    expect(account.ad_daily_metrics.find_by!(date: "2026-09-01").spend).to eq(4)
  end

  it "marks the account's token expired when Google rejects the refresh token" do
    api = FakeGoogleAdsApi.new(error: GoogleAdsApi::AuthError.new("invalid_grant"))

    expect {
      described_class.new(account, api: api).sync_date_range(Date.new(2026, 10, 1), Date.new(2026, 10, 1))
    }.to raise_error(GoogleAdsApi::AuthError)
    expect(account.reload.token_expired?).to be(true)
  end

  it "builds a real client from the account's refresh token and manager id by default" do
    expect(GoogleAdsApi).to receive(:new).with(refresh_token: "test-google-refresh-token", login_customer_id: "6996886629").and_call_original

    described_class.new(account)
  end

  describe "#sync_campaigns" do
    def campaign(id, name: "Shopping US", status: "ENABLED", budget_micros: 30_000_000)
      { "campaign" => { "id" => id, "name" => name, "status" => status },
        "campaignBudget" => { "amountMicros" => budget_micros.to_s } }
    end

    def campaign_day(id, date, cost_micros:, status: "ENABLED", conversions: 2.4, value: 120.555)
      campaign(id, status: status).merge(row(date, cost_micros: cost_micros, conversions: conversions, value: value))
    end

    let(:range) { [ Date.new(2026, 10, 1), Date.new(2026, 10, 2) ] }

    it "saves every listed campaign with its status and daily budget, and one metric per campaign day" do
      api = FakeGoogleAdsApi.new(
        campaigns: [ campaign("111"), campaign("222", name: "PMax", status: "PAUSED", budget_micros: 20_000_000) ],
        campaign_days: [ campaign_day("111", "2026-10-01", cost_micros: 12_345_678) ]
      )

      described_class.new(account, api: api).sync_campaigns(*range)

      shopping = account.ad_campaigns.find_by!(campaign_id: "111")
      expect(shopping).to have_attributes(campaign_name: "Shopping US", status: "active", daily_budget: 30)
      expect(account.ad_campaigns.find_by!(campaign_id: "222")).to have_attributes(campaign_name: "PMax", status: "paused", daily_budget: 20)

      metric = shopping.ad_campaign_daily_metrics.find_by!(date: "2026-10-01")
      expect(metric).to have_attributes(spend: BigDecimal("12.35"), clicks: 10, impressions: 100, purchases: 2,
                                        conversion_value: BigDecimal("120.56"), add_to_cart: 0, checkout_initiated: 0)
      expect(AdCampaignDailyMetric.count).to eq(1)

      queries = api.queries.map(&:last)
      expect(queries.first).to include("campaign.status != 'REMOVED'")
      expect(queries.last).to include("FROM campaign", "BETWEEN '2026-10-01' AND '2026-10-02'")
    end

    it "keeps a removed campaign that still spent in range, marked deleted" do
      api = FakeGoogleAdsApi.new(campaign_days: [ campaign_day("333", "2026-10-02", cost_micros: 5_000_000, status: "REMOVED") ])

      described_class.new(account, api: api).sync_campaigns(*range)

      removed = account.ad_campaigns.find_by!(campaign_id: "333")
      expect(removed.status).to eq("deleted")
      expect(removed.ad_campaign_daily_metrics.sole.spend).to eq(5)
    end

    it "restates reported days and zeroes the account's campaign days in range that are no longer reported" do
      shopping = create(:ad_campaign, ad_account: account, campaign_id: "111", status: "paused")
      create(:ad_campaign_daily_metric, ad_campaign: shopping, date: "2026-10-01", spend: 3)
      stale = create(:ad_campaign_daily_metric, ad_campaign: shopping, date: "2026-10-02", spend: 7, clicks: 4)
      outside = create(:ad_campaign_daily_metric, ad_campaign: shopping, date: "2026-09-30", spend: 9)
      other_account_day = create(:ad_campaign_daily_metric, date: "2026-10-02", spend: 6)

      api = FakeGoogleAdsApi.new(campaigns: [ campaign("111") ],
                                 campaign_days: [ campaign_day("111", "2026-10-01", cost_micros: 8_000_000) ])
      described_class.new(account, api: api).sync_campaigns(*range)

      expect(shopping.reload.status).to eq("active")
      expect(shopping.ad_campaign_daily_metrics.find_by!(date: "2026-10-01").spend).to eq(8)
      expect(stale.reload).to have_attributes(spend: 0, clicks: 0)
      expect(outside.reload.spend).to eq(9)
      expect(other_account_day.reload.spend).to eq(6)
    end

    it "marks the account's token expired when Google rejects the refresh token" do
      api = FakeGoogleAdsApi.new(error: GoogleAdsApi::AuthError.new("invalid_grant"))

      expect { described_class.new(account, api: api).sync_campaigns(*range) }.to raise_error(GoogleAdsApi::AuthError)
      expect(account.reload.token_expired?).to be(true)
    end
  end
end
