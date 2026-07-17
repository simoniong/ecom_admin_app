require "rails_helper"
RSpec.describe ShippingRemoteAreaVersion do
  let(:company) { create(:company) }

  it "requires name, country_code, effective_from" do
    v = ShippingRemoteAreaVersion.new(company: company)
    expect(v).not_to be_valid
    expect(v.errors.attribute_names).to include(:name, :country_code, :effective_from)
  end

  it "rejects effective_to before effective_from" do
    v = build(:shipping_remote_area_version, company: company,
              effective_from: Date.new(2026, 6, 1), effective_to: Date.new(2026, 5, 1))
    expect(v).not_to be_valid
  end

  describe ".lookup" do
    it "picks the latest effective_from on or before the date, honoring effective_to" do
      old = create(:shipping_remote_area_version, company: company, country_code: "GB",
                   effective_from: Date.new(2025, 1, 1), effective_to: nil)
      new = create(:shipping_remote_area_version, company: company, country_code: "GB",
                   effective_from: Date.new(2026, 6, 1), effective_to: nil)
      expect(described_class.lookup(company: company, country: "GB", on_date: Date.new(2026, 5, 10))).to eq(old)
      expect(described_class.lookup(company: company, country: "GB", on_date: Date.new(2026, 6, 1))).to eq(new)
    end

    it "returns nil before the earliest version" do
      create(:shipping_remote_area_version, company: company, country_code: "GB",
             effective_from: Date.new(2026, 1, 1))
      expect(described_class.lookup(company: company, country: "GB", on_date: Date.new(2025, 12, 31))).to be_nil
    end
  end

  describe "#surcharge_for" do
    it "returns the matching rule, preferring the most specific (highest postal_start)" do
      v = create(:shipping_remote_area_version, company: company, country_code: "GB")
      create(:shipping_remote_area_rule, version: v, postal_start: "IV00", postal_end: "IV99",
             surcharge_cny: 17, area_label: "area 2")
      point = create(:shipping_remote_area_rule, version: v, postal_start: "IV63", postal_end: "IV63",
                     surcharge_cny: 25, area_label: "special")
      expect(v.surcharge_for("IV63")).to eq(point)     # most specific wins
      expect(v.surcharge_for("IV01").surcharge_cny).to eq(17)
      expect(v.surcharge_for("BT01")).to be_nil
    end
  end
end
