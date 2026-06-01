require "rails_helper"

RSpec.describe RateCardRateImporter do
  let(:version) { create(:shipping_rate_card_version) }

  it "replaces the version's rates and sets zones" do
    create(:shipping_rate_card_rate, version: version, zone: nil)  # prior row, should be wiped
    text = "1,0,0.25,27,23\n1,0.251,0.3,27,23\n2,0,0.25,27,31"
    result = described_class.new(version: version, text: text).call
    expect(result[:errors]).to be_empty
    expect(result[:count]).to eq(3)
    expect(version.rates.reload.count).to eq(3)
    expect(version.rates.where(zone: "1").count).to eq(2)
    expect(version.rates.find_by(zone: "2", weight_min_kg: 0)).to have_attributes(per_kg_rate_cny: 27, flat_fee_cny: 31)
  end

  it "treats a blank zone as flat (nil)" do
    described_class.new(version: version, text: ",0,0.25,92,25").call
    expect(version.rates.reload.first.zone).to be_nil
  end

  it "aborts and writes nothing on a bad line (max <= min)" do
    create(:shipping_rate_card_rate, version: version)
    before = version.rates.count
    result = described_class.new(version: version, text: "1,0.3,0.3,27,23").call
    expect(result[:errors]).not_to be_empty
    expect(version.rates.reload.count).to eq(before)  # unchanged
  end

  it "aborts on a non-numeric field" do
    result = described_class.new(version: version, text: "1,0,abc,27,23").call
    expect(result[:errors]).not_to be_empty
  end
end
