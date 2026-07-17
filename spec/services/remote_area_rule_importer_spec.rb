require "rails_helper"
RSpec.describe RemoteAreaRuleImporter do
  let(:version) { create(:shipping_remote_area_version, country_code: "GB") }

  it "imports tab- and comma-separated per-code lines, replacing existing rules" do
    create(:shipping_remote_area_rule, version: version) # pre-existing, must be replaced
    text = "AB35\tarea 3\t10\nBT1, area 3, 10\nIV\tarea 2\t17\n"
    result = described_class.new(version: version, text: text).call
    expect(result[:errors]).to be_empty
    expect(result[:count]).to eq(3)
    version.reload
    expect(version.rules.count).to eq(3)
    expect(version.surcharge_for("AB35").surcharge_cny).to eq(10)
    expect(version.surcharge_for("IV63").surcharge_cny).to eq(17) # bare-letter area covers IV63
    expect(version.surcharge_for("BT01").area_label).to eq("area 3")
  end

  it "reports a line error and writes nothing when a token is malformed" do
    text = "AB35, area 3, 10\n@@@, area 2, 17\n"
    result = described_class.new(version: version, text: text).call
    expect(result[:count]).to eq(0)
    expect(result[:errors].first).to match(/Line 2/)
    expect(version.rules.count).to eq(0)
  end

  it "reports an error for a non-numeric price" do
    result = described_class.new(version: version, text: "AB35, area 3, xx").call
    expect(result[:errors]).not_to be_empty
  end
end
