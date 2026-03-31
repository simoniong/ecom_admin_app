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
    stub_request(:get, %r{#{base_url}/orders\.json})
      .to_return(status: 200, body: { orders: orders }.to_json, headers: { "Content-Type" => "application/json" })
  end

  def stub_graphql_refunds(refund_orders, has_next_page: false)
    edges = refund_orders.map.with_index do |order, i|
      {
        "cursor" => "cursor_#{i}",
        "node" => { "refunds" => order[:refunds] }
      }
    end

    body = {
      "data" => {
        "orders" => {
          "edges" => edges,
          "pageInfo" => { "hasNextPage" => has_next_page }
        }
      }
    }

    stub_request(:post, %r{test-store\.myshopify\.com/admin/api/2024-10/graphql\.json})
      .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  describe "#sync_date" do
    it "creates a daily metric with revenue minus refunds" do
      stub_orders_count(18)
      stub_gross_revenue_orders([
        { "subtotal_price" => "120.00", "total_shipping_price_set" => { "shop_money" => { "amount" => "20.00" } }, "total_tax" => "10.00" },
        { "subtotal_price" => "200.00", "total_shipping_price_set" => { "shop_money" => { "amount" => "30.00" } }, "total_tax" => "20.00" }
      ])
      stub_graphql_refunds([
        {
          refunds: [ {
            "createdAt" => Time.current.utc.iso8601,
            "refundLineItems" => { "edges" => [
              { "node" => { "subtotalSet" => { "shopMoney" => { "amount" => "50.00" } } } }
            ] },
            "orderAdjustments" => []
          } ]
        }
      ])

      expect { service.sync_date(Date.current) }.to change(ShopifyDailyMetric, :count).by(1)

      metric = ShopifyDailyMetric.last
      expect(metric.orders_count).to eq(18)
      expect(metric.revenue).to eq(350.00) # 400 gross - 50 refund
    end

    it "accounts for refund discrepancies" do
      stub_orders_count(10)
      stub_gross_revenue_orders([
        { "subtotal_price" => "200.00", "total_shipping_price_set" => { "shop_money" => { "amount" => "10.00" } }, "total_tax" => "0.00" }
      ])
      stub_graphql_refunds([
        {
          refunds: [ {
            "createdAt" => Time.current.utc.iso8601,
            "refundLineItems" => { "edges" => [
              { "node" => { "subtotalSet" => { "shopMoney" => { "amount" => "69.90" } } } }
            ] },
            "orderAdjustments" => [
              { "kind" => "REFUND_DISCREPANCY", "amountSet" => { "shopMoney" => { "amount" => "34.95" } } }
            ]
          } ]
        }
      ])

      service.sync_date(Date.current)
      # Returns = 69.90 - 34.95 = 34.95, Revenue = 210 - 34.95 = 175.05
      expect(ShopifyDailyMetric.last.revenue).to eq(175.05)
    end

    it "filters refunds by date" do
      stub_orders_count(5)
      stub_gross_revenue_orders([
        { "subtotal_price" => "100.00", "total_shipping_price_set" => { "shop_money" => { "amount" => "10.00" } }, "total_tax" => "0.00" }
      ])
      stub_graphql_refunds([
        {
          refunds: [
            { # Today's refund — should be counted
              "createdAt" => Time.current.utc.iso8601,
              "refundLineItems" => { "edges" => [
                { "node" => { "subtotalSet" => { "shopMoney" => { "amount" => "20.00" } } } }
              ] },
              "orderAdjustments" => []
            },
            { # Yesterday's refund — should NOT be counted
              "createdAt" => 1.day.ago.utc.iso8601,
              "refundLineItems" => { "edges" => [
                { "node" => { "subtotalSet" => { "shopMoney" => { "amount" => "99.00" } } } }
              ] },
              "orderAdjustments" => []
            }
          ]
        }
      ])

      service.sync_date(Date.current)
      expect(ShopifyDailyMetric.last.revenue).to eq(90.00) # 110 - 20
    end

    it "handles no refunds" do
      stub_orders_count(5)
      stub_gross_revenue_orders([
        { "subtotal_price" => "100.00", "total_shipping_price_set" => { "shop_money" => { "amount" => "10.00" } }, "total_tax" => "0.00" }
      ])
      stub_graphql_refunds([])

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
