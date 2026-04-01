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

  def stub_graphql(responses)
    call_count = 0
    stub_request(:post, %r{test-store\.myshopify\.com/admin/api/.+/graphql\.json})
      .to_return do
        body = responses[call_count] || empty_graphql_response
        call_count += 1
        { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
      end
  end

  def orders_graphql_response(orders)
    edges = orders.map.with_index do |o, i|
      {
        "cursor" => "cursor_#{i}",
        "node" => {
          "subtotalPriceSet" => { "shopMoney" => { "amount" => o[:subtotal] } },
          "totalShippingPriceSet" => { "shopMoney" => { "amount" => o[:shipping] } },
          "totalTaxSet" => { "shopMoney" => { "amount" => o[:tax] } }
        }
      }
    end
    { "data" => { "orders" => { "edges" => edges, "pageInfo" => { "hasNextPage" => false } } } }
  end

  def refunds_graphql_response(refund_orders)
    edges = refund_orders.map.with_index do |ro, i|
      {
        "cursor" => "cursor_#{i}",
        "node" => { "refunds" => ro[:refunds] }
      }
    end
    { "data" => { "orders" => { "edges" => edges, "pageInfo" => { "hasNextPage" => false } } } }
  end

  def empty_graphql_response
    { "data" => { "orders" => { "edges" => [], "pageInfo" => { "hasNextPage" => false } } } }
  end

  describe "#sync_date" do
    it "creates a daily metric with orders and revenue minus refunds" do
      stub_graphql([
        orders_graphql_response([
          { subtotal: "120.00", shipping: "20.00", tax: "10.00" },
          { subtotal: "200.00", shipping: "30.00", tax: "20.00" }
        ]),
        refunds_graphql_response([
          {
            refunds: [ {
              "createdAt" => Time.current.utc.iso8601,
              "refundLineItems" => { "edges" => [
                { "node" => { "subtotalSet" => { "shopMoney" => { "amount" => "50.00" } } } }
              ] },
              "orderAdjustments" => { "edges" => [] }
            } ]
          }
        ])
      ])

      expect { service.sync_date(Date.current) }.to change(ShopifyDailyMetric, :count).by(1)

      metric = ShopifyDailyMetric.last
      expect(metric.orders_count).to eq(2)
      expect(metric.revenue).to eq(350.00) # 400 gross - 50 refund
    end

    it "accounts for refund discrepancies" do
      stub_graphql([
        orders_graphql_response([ { subtotal: "200.00", shipping: "10.00", tax: "0.00" } ]),
        refunds_graphql_response([
          {
            refunds: [ {
              "createdAt" => Time.current.utc.iso8601,
              "refundLineItems" => { "edges" => [
                { "node" => { "subtotalSet" => { "shopMoney" => { "amount" => "69.90" } } } }
              ] },
              "orderAdjustments" => { "edges" => [
                { "node" => { "reason" => "REFUND_DISCREPANCY", "amountSet" => { "shopMoney" => { "amount" => "34.95" } } } }
              ] }
            } ]
          }
        ])
      ])

      service.sync_date(Date.current)
      expect(ShopifyDailyMetric.last.revenue).to eq(175.05) # 210 - (69.90 - 34.95)
    end

    it "filters refunds by date" do
      stub_graphql([
        orders_graphql_response([ { subtotal: "100.00", shipping: "10.00", tax: "0.00" } ]),
        refunds_graphql_response([
          {
            refunds: [
              {
                "createdAt" => Time.current.utc.iso8601,
                "refundLineItems" => { "edges" => [
                  { "node" => { "subtotalSet" => { "shopMoney" => { "amount" => "20.00" } } } }
                ] },
                "orderAdjustments" => { "edges" => [] }
              },
              {
                "createdAt" => 1.day.ago.utc.iso8601,
                "refundLineItems" => { "edges" => [
                  { "node" => { "subtotalSet" => { "shopMoney" => { "amount" => "99.00" } } } }
                ] },
                "orderAdjustments" => { "edges" => [] }
              }
            ]
          }
        ])
      ])

      service.sync_date(Date.current)
      expect(ShopifyDailyMetric.last.revenue).to eq(90.00) # 110 - 20 (yesterday's refund excluded)
    end

    it "handles no orders and no refunds" do
      stub_graphql([ empty_graphql_response, empty_graphql_response ])

      service.sync_date(Date.current)
      metric = ShopifyDailyMetric.last
      expect(metric.orders_count).to eq(0)
      expect(metric.revenue).to eq(0)
    end

    it "handles API errors gracefully" do
      stub_request(:post, %r{test-store\.myshopify\.com/admin/api/.+/graphql\.json})
        .to_return(status: 500, body: "Internal Server Error")

      expect { service.sync_date(Date.current) }.not_to raise_error
    end
  end
end
