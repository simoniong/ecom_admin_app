require "rails_helper"

RSpec.describe PackageLabelPrinter do
  let(:user)     { create(:user) }
  let(:company)  { user.companies.first }
  let(:store)    { create(:shopify_store, company: company, package_prefix: "XMBDE", package_number_start: 2013094) }
  let(:account)  { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", url2_base: "http://raydo.test:8089") }
  let(:channel)  { create(:logistics_channel, logistics_account: account, product_id: "P1", label_print_type: "lab10_10") }

  def pkg(number:, state: "pending_label", order_id: "R#{number}", chan: channel)
    order = create(:order, shopify_store: store)
    create(:package, shopify_store: store, order: order, number: number, aasm_state: state,
           logistics_channel: chan, raydo_order_id: order_id)
  end

  it "fetches a combined PDF for same-type packages" do
    stub_request(:get, "http://raydo.test:8089/order/FastRpt/PDF_NEW.aspx").
      with(query: { "PrintType" => "lab10_10", "order_id" => "R1,R2" }).
      to_return(body: "%PDF-1.4\nlabels", headers: { "Content-Type" => "application/pdf" })
    result = described_class.new([ pkg(number: 1), pkg(number: 2) ]).call
    expect(result.success?).to be(true)
    expect(result.pdf).to start_with("%PDF")
    expect(result.filename).to eq("labels_2.pdf")
  end

  it "uses the package_code in the filename for a single package" do
    p = pkg(number: 1)
    stub_request(:get, "http://raydo.test:8089/order/FastRpt/PDF_NEW.aspx").with(query: hash_including({})).
      to_return(body: "%PDF-1.4", headers: { "Content-Type" => "application/pdf" })
    expect(described_class.new([ p ]).call.filename).to eq("label_#{p.package_code}.pdf")
  end

  it "fails on empty input" do
    expect(described_class.new([]).call.error).to eq(:empty)
  end

  it "fails when a package is not pending_label" do
    expect(described_class.new([ pkg(number: 1, state: "applying_tracking") ]).call.error).to eq(:invalid_state)
  end

  it "fails when a package has no raydo_order_id" do
    expect(described_class.new([ pkg(number: 1, order_id: nil) ]).call.error).to eq(:no_order)
  end

  it "fails when a package has no logistics channel" do
    p = pkg(number: 1)
    p.update_columns(logistics_channel_id: nil)
    expect(described_class.new([ p ]).call.error).to eq(:no_channel)
  end

  it "fails on mixed label_print_type" do
    other = create(:logistics_channel, logistics_account: account, product_id: "P2", label_print_type: "A4")
    result = described_class.new([ pkg(number: 1), pkg(number: 2, chan: other) ]).call
    expect(result.error).to eq(:mixed_type)
  end

  it "fails when packages span different logistics accounts" do
    # A logistics_account is unique per (company, provider), and provider is
    # always "raydo", so a second raydo account must live in a different
    # company. The service itself has no company scoping (that's the
    # controller's job), so it's legitimate to mix companies here to exercise
    # the guard.
    other_user = create(:user)
    other_company = other_user.companies.first
    other_store = create(:shopify_store, company: other_company, package_prefix: "OTHR", package_number_start: 1)
    other_account = create(:logistics_account, company: other_company, url1_base: "http://raydo2.test:8082", url2_base: "http://raydo2.test:8089")
    other_channel = create(:logistics_channel, logistics_account: other_account, product_id: "P1", label_print_type: "lab10_10")
    other_order = create(:order, shopify_store: other_store)
    other_pkg = create(:package, shopify_store: other_store, order: other_order, number: 1, aasm_state: "pending_label",
                        logistics_channel: other_channel, raydo_order_id: "R2")

    result = described_class.new([ pkg(number: 1), other_pkg ]).call
    expect(result.error).to eq(:mixed_account)
  end

  it "fails when url2_base is missing" do
    account.update!(url2_base: nil)
    expect(described_class.new([ pkg(number: 1) ]).call.error).to eq(:url2_missing)
  end

  it "wraps a Raydo error as a failure result" do
    stub_request(:get, "http://raydo.test:8089/order/FastRpt/PDF_NEW.aspx").with(query: hash_including({})).
      to_return(status: 500, body: "err")
    result = described_class.new([ pkg(number: 1) ]).call
    expect(result.success?).to be(false)
    expect(result.error).to be_a(String)
  end
end
