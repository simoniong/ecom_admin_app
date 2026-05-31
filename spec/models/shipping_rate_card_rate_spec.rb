require "rails_helper"

RSpec.describe ShippingRateCardRate, type: :model do
  describe "validations" do
    it "requires the numeric fields" do
      rate = ShippingRateCardRate.new(flat_fee_cny: nil)
      expect(rate).not_to be_valid
      expect(rate.errors.attribute_names).to include(:weight_min_kg, :weight_max_kg, :per_kg_rate_cny, :flat_fee_cny)
    end

    it "rejects negative per_kg_rate_cny" do
      rate = build(:shipping_rate_card_rate, per_kg_rate_cny: -1)
      expect(rate).not_to be_valid
    end

    it "requires weight_max_kg greater than weight_min_kg" do
      rate = build(:shipping_rate_card_rate, weight_min_kg: 0.5, weight_max_kg: 0.5)
      expect(rate).not_to be_valid
      expect(rate.errors[:weight_max_kg]).to be_present
    end

    it "is valid with a proper band" do
      expect(build(:shipping_rate_card_rate, weight_min_kg: 0.05, weight_max_kg: 0.2)).to be_valid
    end
  end

  describe ".for_weight" do
    let(:version) { create(:shipping_rate_card_version) }
    let!(:band_a) { create(:shipping_rate_card_rate, version: version, weight_min_kg: 0.05, weight_max_kg: 0.2) }
    let!(:band_b) { create(:shipping_rate_card_rate, version: version, weight_min_kg: 0.201, weight_max_kg: 0.45) }

    it "matches the band whose min < W <= max" do
      expect(version.rates.for_weight(0.2)).to contain_exactly(band_a)
      expect(version.rates.for_weight(0.3)).to contain_exactly(band_b)
    end

    it "matches nothing below the lowest band's min" do
      expect(version.rates.for_weight(0.05)).to be_empty
    end
  end

  describe "associations" do
    it "reaches company through version" do
      company = create(:company)
      version = create(:shipping_rate_card_version, company: company)
      rate = create(:shipping_rate_card_rate, version: version)
      expect(rate.company).to eq(company)
    end
  end
end
