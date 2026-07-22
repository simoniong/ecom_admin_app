require "rails_helper"

RSpec.describe PackageShipmentSyncer do
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

  def shipped_ready_package(number: 900)
    order = create(:order, customer: customer, shopify_store: store, shopify_order_id: 5000 + number)
    pkg = create(:package, shopify_store: store, order: order, number: number, aasm_state: "pending_label",
                 logistics_channel: channel, raydo_order_id: "R#{number}", tracking_number: "TN#{number}", carrier: "YunExpress")
    oli = create(:order_line_item, order: order, shopify_line_item_id: 6000 + number, quantity: 2)
    create(:package_item, package: pkg, order_line_item: oli, sku: "A", quantity: 2, refunded_quantity: 0,
           customs_name_en: "Art", customs_name_zh: "画", declared_value_usd: 10, customs_weight_grams: 100)
    pkg
  end

  def sync_pkg
    p = shipped_ready_package; p.update!(aasm_state: "shipped", ship_sync_status: "pending"); p
  end

  def stub_raydo_ok
    stub_request(:get, "http://raydo.test:8082/postOrderApi.htm").with(query: hash_including({})).to_return(body: { ack: "true" }.to_json)
  end

  def stub_17track_ok
    stub_request(:post, "https://api.17track.net/track/v2.4/register").to_return(body: { data: { accepted: [ { number: "TN900" } ], rejected: [] } }.to_json)
  end

  def stub_shopify_ok
    gql = "https://s.myshopify.com/admin/api/2024-10/graphql.json"
    stub_request(:post, gql).to_return do |req|
      body = JSON.parse(req.body)
      if body["query"].include?("fulfillments(")
        { body: { data: { order: { fulfillments: [] } } }.to_json }
      elsif body["query"].include?("fulfillmentOrders")
        { body: { data: { order: { fulfillmentOrders: { edges: [ { node: { id: "gid://shopify/FulfillmentOrder/1", status: "OPEN",
            lineItems: { edges: [ { node: { id: "gid://shopify/FulfillmentOrderLineItem/9", remainingQuantity: 2,
              lineItem: { id: "gid://shopify/LineItem/6900" } } } ] } } } ] } } } }.to_json }
      else
        { body: { data: { fulfillmentCreate: { fulfillment: { id: "gid://shopify/Fulfillment/77" }, userErrors: [] } } }.to_json }
      end
    end
  end

  before { store.company.update!(tracking_enabled: true, tracking_api_key: "k" * 32, tracking_mode: "new_only") }

  it "runs all 3 steps and marks succeeded" do
    stub_raydo_ok; stub_17track_ok; stub_shopify_ok
    p = sync_pkg
    described_class.new(p).call
    p.reload
    expect(p.ship_sync_status).to eq("succeeded")
    expect([ p.carrier_marked_at, p.tracking_registered_at ]).to all(be_present)
    expect(p.shopify_fulfillment_id).to eq("gid://shopify/Fulfillment/77")
  end

  it "is idempotent: skips a step whose completion marker is already set" do
    stub_17track_ok; stub_shopify_ok
    p = sync_pkg; p.update!(carrier_marked_at: 1.hour.ago) # 华磊 already done
    described_class.new(p).call
    expect(WebMock).not_to have_requested(:get, "http://raydo.test:8082/postOrderApi.htm")
    expect(p.reload.ship_sync_status).to eq("succeeded")
  end

  it "marks failed with a safe message when a step errors" do
    stub_raydo_ok
    stub_request(:post, "https://api.17track.net/track/v2.4/register").to_return(status: 500, body: "e")
    p = sync_pkg
    described_class.new(p).call
    p.reload
    expect(p.ship_sync_status).to eq("failed")
    expect(p.ship_sync_message).to be_present
  end

  it "treats 17track as success when it does not raise (already-registered dedupe)" do
    stub_raydo_ok; stub_shopify_ok
    stub_request(:post, "https://api.17track.net/track/v2.4/register").to_return(body: { data: { accepted: [], rejected: [ { number: "TN900", error: { code: -18019902 } } ] } }.to_json)
    p = sync_pkg
    described_class.new(p).call
    expect(p.reload.tracking_registered_at).to be_present
  end

  it "skips 17track (not a failure) when company tracking is not configured" do
    store.company.update!(tracking_enabled: false, tracking_api_key: nil, tracking_mode: nil)
    stub_raydo_ok; stub_shopify_ok
    p = sync_pkg
    described_class.new(p).call
    p.reload
    expect(p.tracking_registered_at).to be_nil
    expect(p.ship_sync_status).to eq("succeeded")
  end
end
