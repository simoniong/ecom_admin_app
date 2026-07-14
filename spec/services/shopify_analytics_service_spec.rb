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
      number_of_orders = o.key?(:number_of_orders) ? o[:number_of_orders] : 5
      customer_node = number_of_orders.nil? ? nil : { "numberOfOrders" => number_of_orders }
      {
        "cursor" => "cursor_#{i}",
        "node" => {
          "subtotalPriceSet" => { "shopMoney" => { "amount" => o[:subtotal] } },
          "totalShippingPriceSet" => { "shopMoney" => { "amount" => o[:shipping] } },
          "totalTaxSet" => { "shopMoney" => { "amount" => o[:tax] } },
          "customer" => customer_node,
          "transactions" => (o[:fees] || []).map { |f| { "fees" => [ { "amount" => { "amount" => f } } ] } }
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

    it "persists the gross / refunds / net-tax / fees breakdown" do
      stub_graphql([
        orders_graphql_response([
          { subtotal: "120.00", shipping: "20.00", tax: "10.00", fees: [ "3.78" ] },
          { subtotal: "200.00", shipping: "30.00", tax: "20.00", fees: [ "6.10", "0.40" ] }
        ]),
        refunds_graphql_response([
          {
            refunds: [ {
              "createdAt" => Time.current.utc.iso8601,
              "refundLineItems" => { "edges" => [
                { "node" => {
                  "subtotalSet" => { "shopMoney" => { "amount" => "50.00" } },
                  "totalTaxSet" => { "shopMoney" => { "amount" => "5.00" } }
                } }
              ] },
              "orderAdjustments" => { "edges" => [] }
            } ]
          }
        ])
      ])

      service.sync_date(Date.current)
      metric = ShopifyDailyMetric.last

      expect(metric.gross_revenue).to eq(400.00)     # 150 + 250
      expect(metric.refunds).to eq(55.00)            # 50 subtotal + 5 tax
      expect(metric.total_tax).to eq(25.00)          # (10 + 20) charged - 5 refunded
      expect(metric.transaction_fees).to eq(10.28)   # 3.78 + 6.10 + 0.40
      expect(metric.revenue).to eq(345.00)           # 400 gross - 55 refunds (unchanged formula)
    end

    it "records zero fees when orders have no Shopify Payments transactions" do
      stub_graphql([
        orders_graphql_response([ { subtotal: "100.00", shipping: "0", tax: "0" } ]),
        empty_graphql_response
      ])

      service.sync_date(Date.current)
      expect(ShopifyDailyMetric.last.transaction_fees).to eq(0)
    end
  end

  describe "#sync_date new-customer counting" do
    it "counts orders where customer.numberOfOrders is 1 as new-customer orders" do
      stub_graphql([
        orders_graphql_response([
          { subtotal: "100.00", shipping: "0", tax: "0", number_of_orders: 1 },
          { subtotal: "100.00", shipping: "0", tax: "0", number_of_orders: 1 },
          { subtotal: "100.00", shipping: "0", tax: "0", number_of_orders: 7 }
        ]),
        empty_graphql_response
      ])

      service.sync_date(Date.current)

      metric = ShopifyDailyMetric.last
      expect(metric.orders_count).to eq(3)
      expect(metric.new_customer_orders_count).to eq(2)
    end

    it "treats orders with no customer as not new (guest checkout)" do
      stub_graphql([
        orders_graphql_response([
          { subtotal: "100.00", shipping: "0", tax: "0", number_of_orders: nil },
          { subtotal: "100.00", shipping: "0", tax: "0", number_of_orders: 1 }
        ]),
        empty_graphql_response
      ])

      service.sync_date(Date.current)

      metric = ShopifyDailyMetric.last
      expect(metric.new_customer_orders_count).to eq(1)
    end

    it "is idempotent: re-running updates the same metric row in place" do
      # Each sync_date makes 3 GraphQL calls: 1 for orders, 2 for refunds (partially_refunded + refunded).
      # Provide the first sync_date's orders at index 0, the second sync_date's orders at index 3.
      # Indices 1, 2, 4, 5 fall through to empty_graphql_response.
      stub_graphql([
        orders_graphql_response([
          { subtotal: "100.00", shipping: "0", tax: "0", number_of_orders: 1 }
        ]),
        empty_graphql_response,
        empty_graphql_response,
        orders_graphql_response([
          { subtotal: "100.00", shipping: "0", tax: "0", number_of_orders: 1 },
          { subtotal: "100.00", shipping: "0", tax: "0", number_of_orders: 1 }
        ])
      ])

      service.sync_date(Date.current)
      expect { service.sync_date(Date.current) }.not_to change(ShopifyDailyMetric, :count)

      expect(ShopifyDailyMetric.last.new_customer_orders_count).to eq(2)
    end
  end
end
