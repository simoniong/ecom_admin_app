require "rails_helper"

RSpec.describe ShippingZonePostalRule, type: :model do
  let(:company) { create(:company) }

  describe "validations" do
    it "requires the key fields" do
      r = described_class.new(company: company)
      expect(r).not_to be_valid
      expect(r.errors.attribute_names).to include(:country_code, :zone, :postal_start, :postal_end)
    end

    it "rejects postal_end before postal_start" do
      r = build(:shipping_zone_postal_rule, company: company, postal_start: "2000", postal_end: "1000")
      expect(r).not_to be_valid
      expect(r.errors[:postal_end]).to be_present
    end
  end

  describe ".zone_for / .country_zoned?" do
    before do
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "1", postal_start: "2000", postal_end: "2079")
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "2", postal_start: "2080", postal_end: "2084")
      create(:shipping_zone_postal_rule, company: company, country_code: "CA", zone: "2", postal_start: "G0A000", postal_end: "G0AZZZ")
      create(:shipping_zone_postal_rule, company: company, country_code: "CA", zone: "1", postal_start: "G0A4V0", postal_end: "G0AZZZ")
    end

    it "matches AU numeric ranges" do
      expect(described_class.zone_for(company: company, country: "AU", key: "2075")).to eq("1")
      expect(described_class.zone_for(company: company, country: "AU", key: "2082")).to eq("2")
    end

    it "returns nil when AU key is outside every range" do
      expect(described_class.zone_for(company: company, country: "AU", key: "9999")).to be_nil
    end

    it "picks the most specific CA rule (greatest postal_start) on overlap" do
      expect(described_class.zone_for(company: company, country: "CA", key: "G0A5A0")).to eq("1")
      expect(described_class.zone_for(company: company, country: "CA", key: "G0A1A0")).to eq("2")
    end

    it "is scoped by company" do
      other = create(:company)
      expect(described_class.zone_for(company: other, country: "AU", key: "2075")).to be_nil
    end

    it "reports country_zoned?" do
      expect(described_class.country_zoned?(company: company, country: "AU")).to be(true)
      expect(described_class.country_zoned?(company: company, country: "US")).to be(false)
    end

    it "strips whitespace on zone" do
      r = create(:shipping_zone_postal_rule, company: company, zone: " 2 ")
      expect(r.zone).to eq("2")
    end
  end
end
