require "rails_helper"

RSpec.describe GoogleAdsService do
  # Stands in for GoogleAdsApi: records the query and returns canned rows.
  class FakeGoogleAdsApi
    attr_reader :queries

    def initialize(rows = [], error: nil)
      @rows = rows
      @error = error
      @queries = []
    end

    def search(customer_id, query)
      raise @error if @error

      @queries << [ customer_id, query ]
      @rows
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
end
