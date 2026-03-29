require "rails_helper"

RSpec.describe ShopifyAnalyticsService do
  let(:store) { create(:shopify_store, shop_domain: "test-store.myshopify.com", access_token: "shpat_test") }
  let(:service) do
    described_class.new(
      shop_domain: store.shop_domain,
      access_token: store.access_token,
      store_id: store.id
    )
  end
  let(:base_url) { "https://test-store.myshopify.com/admin/api/2024-10" }

  def stub_orders_count(count)
    stub_request(:get, %r{#{base_url}/orders/count\.json})
      .to_return(status: 200, body: { count: count }.to_json, headers: { "Content-Type" => "application/json" })
  end

  def stub_orders(orders)
    stub_request(:get, %r{#{base_url}/orders\.json})
      .to_return(status: 200, body: { orders: orders }.to_json, headers: { "Content-Type" => "application/json" })
  end

  describe "#sync_date" do
    it "creates a daily metric from Shopify REST API" do
      stub_orders_count(18)
      stub_orders([ { "total_price" => "150.00" }, { "total_price" => "250.00" } ])

      expect { service.sync_date(Date.current) }.to change(ShopifyDailyMetric, :count).by(1)

      metric = ShopifyDailyMetric.last
      expect(metric.orders_count).to eq(18)
      expect(metric.revenue).to eq(400.00)
      expect(metric.shopify_store_id).to eq(store.id)
    end

    it "updates existing metric" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, orders_count: 5)
      stub_orders_count(25)
      stub_orders([])

      expect { service.sync_date(Date.current) }.not_to change(ShopifyDailyMetric, :count)

      metric = ShopifyDailyMetric.find_by(shopify_store_id: store.id, date: Date.current)
      expect(metric.orders_count).to eq(25)
    end

    it "handles empty orders response" do
      stub_orders_count(0)
      stub_orders([])

      service.sync_date(Date.current)
      metric = ShopifyDailyMetric.last
      expect(metric.orders_count).to eq(0)
      expect(metric.revenue).to eq(0)
    end

    it "handles API errors gracefully" do
      stub_request(:get, %r{#{base_url}/orders/count\.json})
        .to_return(status: 500, body: "Internal Server Error")

      expect { service.sync_date(Date.current) }.not_to raise_error
    end
  end
end
