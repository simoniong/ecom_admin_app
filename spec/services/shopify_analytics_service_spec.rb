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

  def stub_gross_revenue_orders(orders)
    stub_request(:get, %r{#{base_url}/orders\.json.*created_at_min})
      .to_return(status: 200, body: { orders: orders }.to_json, headers: { "Content-Type" => "application/json" })
  end

  def stub_refund_orders(orders)
    stub_request(:get, %r{#{base_url}/orders\.json.*updated_at_min})
      .to_return(status: 200, body: { orders: orders }.to_json, headers: { "Content-Type" => "application/json" })
  end

  describe "#sync_date" do
    it "creates a daily metric with revenue minus refunds" do
      stub_orders_count(18)
      stub_gross_revenue_orders([
        { "subtotal_price" => "120.00", "total_shipping_price_set" => { "shop_money" => { "amount" => "20.00" } }, "total_tax" => "10.00" },
        { "subtotal_price" => "200.00", "total_shipping_price_set" => { "shop_money" => { "amount" => "30.00" } }, "total_tax" => "20.00" }
      ])
      stub_refund_orders([
        {
          "refunds" => [ {
            "created_at" => Time.current.iso8601,
            "refund_line_items" => [ { "subtotal" => "50.00" } ],
            "order_adjustments" => []
          } ]
        }
      ])

      expect { service.sync_date(Date.current) }.to change(ShopifyDailyMetric, :count).by(1)

      metric = ShopifyDailyMetric.last
      expect(metric.orders_count).to eq(18)
      expect(metric.revenue).to eq(350.00) # 400 gross - 50 refund
    end

    it "updates existing metric" do
      create(:shopify_daily_metric, shopify_store: store, date: Date.current, orders_count: 5)
      stub_orders_count(25)
      stub_gross_revenue_orders([])
      stub_refund_orders([])

      expect { service.sync_date(Date.current) }.not_to change(ShopifyDailyMetric, :count)
      expect(ShopifyDailyMetric.find_by(shopify_store_id: store.id, date: Date.current).orders_count).to eq(25)
    end

    it "handles no refunds" do
      stub_orders_count(5)
      stub_gross_revenue_orders([
        { "subtotal_price" => "100.00", "total_shipping_price_set" => { "shop_money" => { "amount" => "10.00" } }, "total_tax" => "0.00" }
      ])
      stub_refund_orders([])

      service.sync_date(Date.current)
      expect(ShopifyDailyMetric.last.revenue).to eq(110.00)
    end

    it "handles API errors gracefully" do
      stub_request(:get, %r{#{base_url}/orders/count\.json})
        .to_return(status: 500, body: "Internal Server Error")

      expect { service.sync_date(Date.current) }.not_to raise_error
    end
  end
end
