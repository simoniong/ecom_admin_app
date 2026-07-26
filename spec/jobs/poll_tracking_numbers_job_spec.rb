require "rails_helper"

RSpec.describe PollTrackingNumbersJob do
  let(:company) { create(:company) }
  let(:store)   { create(:shopify_store, company: company, package_prefix: "XMBDE", package_number_start: 2013094) }
  let(:account) { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", customer_id: "1", customer_userid: "2") }
  let(:channel) { create(:logistics_channel, logistics_account: account, product_id: "P1") }

  def pending_package(order_id:, applied_at:)
    order = create(:order, shopify_store: store)
    create(:package, shopify_store: store, order: order, aasm_state: "applying_tracking", application_status: "pending",
           logistics_channel: channel, raydo_order_id: order_id, applied_at: applied_at,
           shipping_address_snapshot: { "name" => "A", "address1" => "x", "city" => "P", "country_code" => "FR", "phone" => "1" })
  end

  it "moves a package to pending_label when the number is now out" do
    pkg = pending_package(order_id: "R1", applied_at: 1.hour.ago)
    stub_request(:get, "http://raydo.test:8082/getOrderTrackingNumber.htm").with(query: { order_id: "R1" }).
      to_return(body: { status: "200", order_serveinvoicecode: "SF1" }.to_json)
    described_class.perform_now
    expect(pkg.reload).to have_state(:pending_label)
    expect(pkg.tracking_number).to eq("SF1")
  end

  it "gives up (failed) after 24h with a timeout message, without polling" do
    pkg = pending_package(order_id: "R2", applied_at: 25.hours.ago)
    described_class.perform_now
    pkg.reload
    expect(pkg.application_status).to eq("failed")
    expect(pkg.application_message).to eq(I18n.t("packages.apply.timeout"))
    expect(WebMock).not_to have_requested(:get, "http://raydo.test:8082/getOrderTrackingNumber.htm")
  end

  it "leaves a not-yet-out package pending" do
    pkg = pending_package(order_id: "R3", applied_at: 1.hour.ago)
    stub_request(:get, "http://raydo.test:8082/getOrderTrackingNumber.htm").with(query: { order_id: "R3" }).
      to_return(body: { status: "200", order_serveinvoicecode: "" }.to_json)
    described_class.perform_now
    expect(pkg.reload).to have_state(:applying_tracking)
    expect(pkg.application_status).to eq("pending")
  end

  it "ignores packages without a raydo_order_id" do
    order = create(:order, shopify_store: store)
    create(:package, shopify_store: store, order: order, aasm_state: "applying_tracking", application_status: "pending", raydo_order_id: nil)
    expect { described_class.perform_now }.not_to raise_error
  end
end
