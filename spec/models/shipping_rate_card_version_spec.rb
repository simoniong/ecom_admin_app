require "rails_helper"

RSpec.describe ShippingRateCardVersion, type: :model do
  let(:company) { create(:company) }

  describe "validations" do
    it "requires name, country_code, service_type, effective_from" do
      version = ShippingRateCardVersion.new(company: company)
      expect(version).not_to be_valid
      expect(version.errors.attribute_names).to include(:name, :country_code, :service_type, :effective_from)
    end

    it "rejects effective_to earlier than effective_from" do
      version = build(:shipping_rate_card_version, company: company,
                      effective_from: Date.new(2026, 3, 1), effective_to: Date.new(2026, 2, 1))
      expect(version).not_to be_valid
      expect(version.errors[:effective_to]).to be_present
    end

    it "allows effective_to equal to effective_from" do
      version = build(:shipping_rate_card_version, company: company,
                      effective_from: Date.new(2026, 3, 1), effective_to: Date.new(2026, 3, 1))
      expect(version).to be_valid
    end

    it "allows a nil effective_to" do
      version = build(:shipping_rate_card_version, company: company, effective_to: nil)
      expect(version).to be_valid
    end

    it "rejects a country_code outside the supported list" do
      version = build(:shipping_rate_card_version, company: company, country_code: "ZZ")
      expect(version).not_to be_valid
      expect(version.errors[:country_code]).to be_present
    end

    it "rejects a service_type outside the canonical list" do
      version = build(:shipping_rate_card_version, company: company, service_type: "standard_with_battery")
      expect(version).not_to be_valid
      expect(version.errors[:service_type]).to be_present
    end

    it "accepts the canonical service types and supported countries" do
      ShippingRateCardVersion::SERVICE_TYPES.each do |st|
        expect(build(:shipping_rate_card_version, company: company, service_type: st)).to be_valid
      end
      ShippingRateCardVersion::COUNTRY_CODES.each do |cc|
        expect(build(:shipping_rate_card_version, company: company, country_code: cc)).to be_valid
      end
    end
  end

  describe ".lookup" do
    let(:lookup_args)  { { country: "US", service_type: "with_battery" } }
    let(:factory_args) { { country_code: "US", service_type: "with_battery" } }

    it "returns the newest applicable version for the date" do
      old = create(:shipping_rate_card_version, company: company,
                   effective_from: Date.new(2026, 1, 1), effective_to: nil, **factory_args)
      new_v = create(:shipping_rate_card_version, company: company,
                     effective_from: Date.new(2026, 4, 1), effective_to: nil, **factory_args)

      expect(described_class.lookup(company: company, on_date: Date.new(2026, 5, 1), **lookup_args)).to eq(new_v)
      expect(described_class.lookup(company: company, on_date: Date.new(2026, 2, 1), **lookup_args)).to eq(old)
    end

    it "falls back to the most recent past version when none explicitly contains the date" do
      old = create(:shipping_rate_card_version, company: company,
                   effective_from: Date.new(2026, 1, 1), effective_to: nil, **factory_args)
      expect(described_class.lookup(company: company, on_date: Date.new(2026, 12, 31), **lookup_args)).to eq(old)
    end

    it "returns nil when no version covers the date" do
      create(:shipping_rate_card_version, company: company,
             effective_from: Date.new(2026, 6, 1), effective_to: nil, **factory_args)
      expect(described_class.lookup(company: company, on_date: Date.new(2026, 1, 1), **lookup_args)).to be_nil
    end

    it "excludes a version whose effective_to has passed" do
      create(:shipping_rate_card_version, company: company,
             effective_from: Date.new(2026, 1, 1), effective_to: Date.new(2026, 3, 31), **factory_args)
      expect(described_class.lookup(company: company, on_date: Date.new(2026, 5, 1), **lookup_args)).to be_nil
    end

    it "scopes by company" do
      other = create(:company)
      create(:shipping_rate_card_version, company: other,
             effective_from: Date.new(2026, 1, 1), **factory_args)
      expect(described_class.lookup(company: company, on_date: Date.new(2026, 5, 1), **lookup_args)).to be_nil
    end
  end

  describe "associations" do
    it "destroys its rates when destroyed" do
      version = create(:shipping_rate_card_version, company: company)
      create(:shipping_rate_card_rate, version: version)
      expect { version.destroy }.to change(ShippingRateCardRate, :count).by(-1)
    end
  end
end
