require "rails_helper"

RSpec.describe ShopifyFulfillmentService do
  let(:user)    { create(:user) }
  let(:company) { user.companies.first }
  let(:store) do
    create(:shopify_store, user: user, company: company, package_prefix: "XMBDE", package_number_start: 2013094,
           shop_domain: "s.myshopify.com", access_token: "shpat_x",
           scopes: "read_all_orders,write_merchant_managed_fulfillment_orders")
  end
  let(:customer) { create(:customer, shopify_store: store) }
  let(:account) do
    create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", url2_base: "http://raydo.test:8089",
           customer_id: "6581", customer_userid: "6901")
  end
  let(:channel) do
    create(:logistics_channel, logistics_account: account, product_id: "P1", shopify_carrier_name: "YunExpress",
           tracking_url_template: "https://t.17track.net/en#nums=#TrackingNumber#")
  end

  let(:gql) { "https://s.myshopify.com/admin/api/2024-10/graphql.json" }

  def shipped_ready_package(number: 900)
    order = create(:order, customer: customer, shopify_store: store, shopify_order_id: 5000 + number)
    pkg = create(:package, shopify_store: store, order: order, number: number, aasm_state: "pending_label",
                 logistics_channel: channel, raydo_order_id: "R#{number}", tracking_number: "TN#{number}", carrier: "YunExpress")
    oli = create(:order_line_item, order: order, shopify_line_item_id: 6000 + number, quantity: 2)
    create(:package_item, package: pkg, order_line_item: oli, sku: "A", quantity: 2, refunded_quantity: 0,
           customs_name_en: "Art", customs_name_zh: "画", declared_value_usd: 10, customs_weight_grams: 100)
    pkg
  end

  it "creates a fulfillment for the package's line items and returns its id" do
    pkg = shipped_ready_package
    calls = []
    stub_request(:post, gql).to_return do |req|
      body = JSON.parse(req.body); calls << body
      if body["query"].include?("fulfillments(") # reconcile query → none
        { body: { data: { order: { fulfillments: [] } } }.to_json }
      elsif body["query"].include?("fulfillmentOrders")
        { body: { data: { order: { fulfillmentOrders: { edges: [ { node: { id: "gid://shopify/FulfillmentOrder/1", status: "OPEN",
            lineItems: { edges: [ { node: { id: "gid://shopify/FulfillmentOrderLineItem/9", remainingQuantity: 2,
              lineItem: { id: "gid://shopify/LineItem/#{6000 + 900}" } } } ] } } } ] } } } }.to_json }
      else # fulfillmentCreate
        { body: { data: { fulfillmentCreate: { fulfillment: { id: "gid://shopify/Fulfillment/77" }, userErrors: [] } } }.to_json }
      end
    end
    expect(described_class.new(pkg).call).to eq("gid://shopify/Fulfillment/77")
    create_call = calls.find { |c| c["query"].include?("fulfillmentCreate") }
    fo = create_call.dig("variables", "fulfillment", "lineItemsByFulfillmentOrder").first
    expect(fo["fulfillmentOrderId"]).to eq("gid://shopify/FulfillmentOrder/1")
    expect(fo["fulfillmentOrderLineItems"]).to eq([ { "id" => "gid://shopify/FulfillmentOrderLineItem/9", "quantity" => 2 } ])
    expect(create_call.dig("variables", "fulfillment", "trackingInfo")).to include("number" => "TN900", "company" => "YunExpress")
    expect(create_call.dig("variables", "fulfillment", "notifyCustomer")).to be(true)
  end

  it "reconciles: adopts an existing fulfillment with the same tracking number (no re-create)" do
    pkg = shipped_ready_package
    stub_request(:post, gql).to_return do |req|
      body = JSON.parse(req.body)
      raise "should not create" if body["query"].include?("fulfillmentCreate")
      { body: { data: { order: { fulfillments: [ { id: "gid://shopify/Fulfillment/55", trackingInfo: [ { number: "TN900" } ] } ] } } }.to_json }
    end
    expect(described_class.new(pkg).call).to eq("gid://shopify/Fulfillment/55")
  end

  it "raises on userErrors" do
    pkg = shipped_ready_package
    stub_request(:post, gql).to_return do |req|
      body = JSON.parse(req.body)
      if body["query"].include?("fulfillments(")
        { body: { data: { order: { fulfillments: [] } } }.to_json }
      elsif body["query"].include?("fulfillmentOrders")
        { body: { data: { order: { fulfillmentOrders: { edges: [ { node: { id: "gid://shopify/FulfillmentOrder/1", status: "OPEN",
            lineItems: { edges: [ { node: { id: "gid://shopify/FulfillmentOrderLineItem/9", remainingQuantity: 2,
              lineItem: { id: "gid://shopify/LineItem/6900" } } } ] } } } ] } } } }.to_json }
      else
        { body: { data: { fulfillmentCreate: { fulfillment: nil, userErrors: [ { field: [ "fulfillment" ], message: "cannot" } ] } } }.to_json }
      end
    end
    expect { described_class.new(pkg).call }.to raise_error(ShopifyFulfillmentService::Error, /cannot/)
  end

  it "raises when there is no open fulfillment order" do
    pkg = shipped_ready_package
    stub_request(:post, gql).to_return do |req|
      body = JSON.parse(req.body)
      if body["query"].include?("fulfillments(")
        { body: { data: { order: { fulfillments: [] } } }.to_json }
      else
        { body: { data: { order: { fulfillmentOrders: { edges: [] } } } }.to_json }
      end
    end
    expect { described_class.new(pkg).call }.to raise_error(ShopifyFulfillmentService::Error, /no open fulfillment/i)
  end

  it "raises when the store lacks the fulfillment write scope" do
    pkg = shipped_ready_package
    pkg.shopify_store.update!(scopes: "read_all_orders")
    expect { described_class.new(pkg).call }.to raise_error(ShopifyFulfillmentService::Error, /scope|reauth/i)
  end
end
