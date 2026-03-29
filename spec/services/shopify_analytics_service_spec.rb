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

  describe "#sync_date" do
    it "creates a daily metric with sessions and order data" do
      customer = create(:customer)
      create(:order, customer: customer, ordered_at: Date.current.noon, total_price: 100)
      create(:order, customer: customer, ordered_at: Date.current.noon, total_price: 200)

      # Mock ShopifyQL response
      graphql_client = instance_double(ShopifyAPI::Clients::Graphql::Admin)
      allow(ShopifyAPI::Clients::Graphql::Admin).to receive(:new).and_return(graphql_client)

      response_body = {
        "data" => {
          "shopifyqlQuery" => {
            "tableData" => {
              "rowData" => [ [ "150" ] ],
              "columns" => [ { "name" => "count", "dataType" => "NUMBER" } ]
            }
          }
        }
      }
      allow(graphql_client).to receive(:query).and_return(OpenStruct.new(body: response_body))

      expect { service.sync_date(Date.current) }.to change(ShopifyDailyMetric, :count).by(1)

      metric = ShopifyDailyMetric.last
      expect(metric.sessions).to eq(150)
      expect(metric.orders_count).to eq(2)
      expect(metric.revenue).to eq(300)
      expect(metric.shopify_store_id).to eq(store.id)
    end

    it "updates existing metric" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, sessions: 50)

      graphql_client = instance_double(ShopifyAPI::Clients::Graphql::Admin)
      allow(ShopifyAPI::Clients::Graphql::Admin).to receive(:new).and_return(graphql_client)

      response_body = {
        "data" => {
          "shopifyqlQuery" => {
            "tableData" => {
              "rowData" => [ [ "200" ] ],
              "columns" => []
            }
          }
        }
      }
      allow(graphql_client).to receive(:query).and_return(OpenStruct.new(body: response_body))

      expect { service.sync_date(Date.current) }.not_to change(ShopifyDailyMetric, :count)

      metric = ShopifyDailyMetric.find_by(shopify_store_id: store.id, date: Date.current)
      expect(metric.sessions).to eq(200)
    end

    it "returns 0 sessions when ShopifyQL returns empty data" do
      graphql_client = instance_double(ShopifyAPI::Clients::Graphql::Admin)
      allow(ShopifyAPI::Clients::Graphql::Admin).to receive(:new).and_return(graphql_client)

      response_body = {
        "data" => {
          "shopifyqlQuery" => {
            "tableData" => {
              "rowData" => [],
              "columns" => []
            }
          }
        }
      }
      allow(graphql_client).to receive(:query).and_return(OpenStruct.new(body: response_body))

      service.sync_date(Date.current)
      metric = ShopifyDailyMetric.last
      expect(metric.sessions).to eq(0)
    end

    it "handles API errors gracefully and returns 0 sessions" do
      graphql_client = instance_double(ShopifyAPI::Clients::Graphql::Admin)
      allow(ShopifyAPI::Clients::Graphql::Admin).to receive(:new).and_return(graphql_client)
      allow(graphql_client).to receive(:query).and_raise(RuntimeError, "API error")

      service.sync_date(Date.current)
      metric = ShopifyDailyMetric.last
      expect(metric.sessions).to eq(0)
    end
  end
end
