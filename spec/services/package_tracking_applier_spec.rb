require "rails_helper"

RSpec.describe PackageTrackingApplier do
  let(:company) { create(:company) }
  let(:store)   { create(:shopify_store, company: company, package_prefix: "XMBDE", package_number_start: 2013094) }
  let(:account) { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", customer_id: "6581", customer_userid: "6901") }
  let(:channel) { create(:logistics_channel, logistics_account: account, product_id: "P1") }
  let(:package) do
    order = create(:order, shopify_store: store)
    pkg = create(:package, shopify_store: store, order: order, number: 2013094, aasm_state: "applying_tracking",
                 application_status: "pending", logistics_channel: channel,
                 shipping_address_snapshot: { "name" => "Amy", "address1" => "1 Rue", "city" => "Paris", "country_code" => "FR", "phone" => "1" })
    oli = create(:order_line_item, order: order)
    create(:package_item, package: pkg, order_line_item: oli, sku: "A", quantity: 1,
           customs_name_zh: "画", customs_name_en: "Painting", declared_value_usd: 10, customs_weight_grams: 100)
    pkg
  end

  it "creates an order and moves to pending_label when the tracking number is immediate" do
    stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
      to_return(body: { ack: "true", order_id: "R1", tracking_number: "TN1" }.to_json)
    described_class.new(package).call
    package.reload
    expect(package).to have_state(:pending_label)
    expect(package.application_status).to eq("succeeded")
    expect([ package.raydo_order_id, package.tracking_number ]).to eq([ "R1", "TN1" ])
    expect(package.applied_at).to be_present
  end

  it "stays pending (applying_tracking) and stores order_id when deferred" do
    stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
      to_return(body: { ack: "true", order_id: "R2", tracking_number: "", is_delay: "Y" }.to_json)
    described_class.new(package).call
    package.reload
    expect(package).to have_state(:applying_tracking)
    expect(package.application_status).to eq("pending")
    expect(package.raydo_order_id).to eq("R2")
    expect(package.tracking_number).to be_nil
  end

  it "marks failed with the message on ack=false, staying in applying_tracking" do
    stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
      to_return(body: { ack: "false", message: "%E5%9C%B0%E5%9D%80%E9%94%99%E8%AF%AF" }.to_json)
    described_class.new(package).call
    package.reload
    expect(package).to have_state(:applying_tracking)
    expect(package.application_status).to eq("failed")
    expect(package.application_message).to eq("地址错误")
  end

  it "polls (does not re-create) when raydo_order_id already exists, succeeding on ready" do
    package.update!(raydo_order_id: "R9", application_status: "failed")
    stub = stub_request(:get, "http://raydo.test:8082/getOrderTrackingNumber.htm").
      with(query: { order_id: "R9" }).
      to_return(body: { status: "200", order_serveinvoicecode: "SF9", express_type: "SF" }.to_json)
    described_class.new(package).call
    package.reload
    expect(stub).to have_been_requested
    expect(package).to have_state(:pending_label)
    expect(package.tracking_number).to eq("SF9")
    expect(package.carrier).to eq("SF")
  end

  it "leaves the package pending (no fail) when a poll errors transiently" do
    package.update!(raydo_order_id: "R9", application_status: "pending")
    stub_request(:get, "http://raydo.test:8082/getOrderTrackingNumber.htm").with(query: { order_id: "R9" }).to_timeout
    described_class.new(package).call
    package.reload
    expect(package).to have_state(:applying_tracking)
    expect(package.application_status).to eq("pending")
  end

  it "fails when logistics is not configured" do
    package.update!(logistics_channel: nil)
    described_class.new(package).call
    expect(package.reload.application_status).to eq("failed")
  end
end
