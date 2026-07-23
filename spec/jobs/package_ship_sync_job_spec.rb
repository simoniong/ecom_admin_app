require "rails_helper"

RSpec.describe PackageShipSyncJob do
  let(:user) { create(:user) }
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

  it "syncs a shipped package" do
    store.company.update!(tracking_enabled: false, tracking_api_key: nil)
    p = shipped_ready_package; p.update!(aasm_state: "shipped", ship_sync_status: "pending", carrier_marked_at: 1.hour.ago, shopify_fulfillment_id: "gid://shopify/Fulfillment/1")
    described_class.perform_now(p.id)
    expect(p.reload.ship_sync_status).to eq("succeeded")
  end

  it "no-ops for a non-shipped package" do
    p = shipped_ready_package # pending_label
    described_class.perform_now(p.id)
    expect(p.reload.ship_sync_status).to eq("none")
  end

  it "no-ops for a missing id" do
    expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
  end
end
