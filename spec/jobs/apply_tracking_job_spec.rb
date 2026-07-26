require "rails_helper"

RSpec.describe ApplyTrackingJob do
  let(:company) { create(:company) }
  let(:store)   { create(:shopify_store, company: company, package_prefix: "XMBDE", package_number_start: 2013094) }
  let(:account) { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", customer_id: "1", customer_userid: "2") }
  let(:channel) { create(:logistics_channel, logistics_account: account, product_id: "P1") }
  let(:package) do
    order = create(:order, shopify_store: store)
    pkg = create(:package, shopify_store: store, order: order, aasm_state: "applying_tracking",
                 application_status: "pending", logistics_channel: channel,
                 shipping_address_snapshot: { "name" => "A", "address1" => "x", "city" => "P", "country_code" => "FR", "phone" => "1" })
    create(:package_item, package: pkg, order_line_item: create(:order_line_item, order: order), sku: "A", quantity: 1,
           customs_name_en: "Art", customs_name_zh: "画", declared_value_usd: 5, customs_weight_grams: 100)
    pkg
  end

  it "applies for the tracking number of an applying_tracking package" do
    stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
      to_return(body: { ack: "true", order_id: "R1", tracking_number: "TN1" }.to_json)
    described_class.perform_now(package.id)
    expect(package.reload).to have_state(:pending_label)
  end

  it "no-ops for a package no longer in applying_tracking" do
    package.update!(aasm_state: "pending_process", application_status: "none")
    described_class.perform_now(package.id)
    expect(WebMock).not_to have_requested(:post, "http://raydo.test:8082/createOrderApi.htm")
  end

  it "no-ops for a missing package id" do
    expect { described_class.perform_now(SecureRandom.uuid) }.not_to raise_error
  end
end
