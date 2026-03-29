require "rails_helper"

RSpec.describe ShopifyAnalyticsService do
  let(:store) { create(:shopify_store) }
  let(:service) do
    described_class.new(
      shop_domain: store.shop_domain,
      access_token: store.access_token,
      store_id: store.id
    )
  end

  def mock_graphql_client(responses)
    graphql_client = instance_double(ShopifyAPI::Clients::Graphql::Admin)
    allow(ShopifyAPI::Clients::Graphql::Admin).to receive(:new).and_return(graphql_client)

    call_count = 0
    allow(graphql_client).to receive(:query) do
      value = responses[call_count] || 0
      call_count += 1
      OpenStruct.new(body: {
        "data" => {
          "shopifyqlQuery" => {
            "tableData" => {
              "rowData" => value.nil? ? [] : [ [ value.to_s ] ],
              "columns" => [ { "name" => "count", "dataType" => "NUMBER" } ]
            }
          }
        }
      })
    end

    graphql_client
  end

  describe "#sync_date" do
    it "creates a daily metric from ShopifyQL data" do
      # responses: sessions=150, orders=10, revenue=1500
      mock_graphql_client([ 150, 10, 1500 ])

      expect { service.sync_date(Date.current) }.to change(ShopifyDailyMetric, :count).by(1)

      metric = ShopifyDailyMetric.last
      expect(metric.sessions).to eq(150)
      expect(metric.orders_count).to eq(10)
      expect(metric.revenue).to eq(1500)
      expect(metric.conversion_rate).to be_within(0.001).of(10.0 / 150)
      expect(metric.shopify_store_id).to eq(store.id)
    end

    it "updates existing metric" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, sessions: 50)
      mock_graphql_client([ 200, 15, 2000 ])

      expect { service.sync_date(Date.current) }.not_to change(ShopifyDailyMetric, :count)

      metric = ShopifyDailyMetric.find_by(shopify_store_id: store.id, date: Date.current)
      expect(metric.sessions).to eq(200)
      expect(metric.orders_count).to eq(15)
    end

    it "returns 0 when ShopifyQL returns empty data" do
      mock_graphql_client([ nil, nil, nil ])

      service.sync_date(Date.current)
      metric = ShopifyDailyMetric.last
      expect(metric.sessions).to eq(0)
      expect(metric.orders_count).to eq(0)
      expect(metric.revenue).to eq(0)
    end

    it "sets conversion_rate to 0 when no sessions" do
      mock_graphql_client([ 0, 5, 500 ])

      service.sync_date(Date.current)
      metric = ShopifyDailyMetric.last
      expect(metric.conversion_rate).to eq(0)
    end

    it "handles API errors gracefully" do
      graphql_client = instance_double(ShopifyAPI::Clients::Graphql::Admin)
      allow(ShopifyAPI::Clients::Graphql::Admin).to receive(:new).and_return(graphql_client)
      allow(graphql_client).to receive(:query).and_raise(RuntimeError, "API error")

      service.sync_date(Date.current)
      metric = ShopifyDailyMetric.last
      expect(metric.sessions).to eq(0)
      expect(metric.orders_count).to eq(0)
      expect(metric.revenue).to eq(0)
    end
  end
end
