require "rails_helper"

RSpec.describe PostalZoneImporter do
  let(:company) { create(:company) }

  describe "AU import" do
    let(:text) { "1: 1000-1935, 2000-2079, 2158\n2: 2080-2084, 200-299" }

    it "replaces the country's rows and reports the count" do
      result = described_class.new(company: company, country: "AU", text: text).call
      expect(result[:errors]).to be_empty
      expect(result[:count]).to eq(5)
      rules = company.shipping_zone_postal_rules.where(country_code: "AU")
      expect(rules.count).to eq(5)
      expect(rules.find_by(postal_start: "0200")).to have_attributes(postal_end: "0299", zone: "2")
      expect(ShippingZonePostalRule.zone_for(company: company, country: "AU", key: "2075")).to eq("1")
    end

    it "wipes prior AU rows on re-import (replace semantics)" do
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "9", postal_start: "5000", postal_end: "5001")
      described_class.new(company: company, country: "AU", text: text).call
      expect(company.shipping_zone_postal_rules.where(country_code: "AU", zone: "9")).to be_empty
    end

    it "aborts and writes nothing when a line is malformed" do
      bad = "1: 1000-1935\n2: oops-bad"
      result = described_class.new(company: company, country: "AU", text: bad).call
      expect(result[:errors]).not_to be_empty
      expect(company.shipping_zone_postal_rules.where(country_code: "AU").count).to eq(0)
    end

    it "does not touch other countries" do
      create(:shipping_zone_postal_rule, company: company, country_code: "CA", zone: "1", postal_start: "G0A000", postal_end: "G0AZZZ")
      described_class.new(company: company, country: "AU", text: text).call
      expect(company.shipping_zone_postal_rules.where(country_code: "CA").count).to eq(1)
    end
  end

  describe "CA import" do
    let(:text) { "G0A4V0,1\nG0B,1\nV9N,2" }

    it "expands FSA (3) and full (6) tokens correctly" do
      result = described_class.new(company: company, country: "CA", text: text).call
      expect(result[:errors]).to be_empty
      expect(result[:count]).to eq(3)
      expect(ShippingZonePostalRule.zone_for(company: company, country: "CA", key: "V9N5A0")).to eq("2")
      expect(ShippingZonePostalRule.zone_for(company: company, country: "CA", key: "G0A5A0")).to eq("1")
    end

    it "aborts on a bad CA token" do
      result = described_class.new(company: company, country: "CA", text: "G0A4V0,1\nXX,2").call
      expect(result[:errors]).not_to be_empty
      expect(company.shipping_zone_postal_rules.where(country_code: "CA").count).to eq(0)
    end
  end

  describe "unsupported country / blank zone guards" do
    let(:company) { create(:company) }

    it "rejects an unsupported country and writes nothing" do
      result = described_class.new(company: company, country: "US", text: "1: 2000-2079").call
      expect(result[:errors]).not_to be_empty
      expect(company.shipping_zone_postal_rules.count).to eq(0)
    end

    it "rejects a CA line with a blank zone" do
      result = described_class.new(company: company, country: "CA", text: "G0A4V0,").call
      expect(result[:errors]).not_to be_empty
      expect(company.shipping_zone_postal_rules.where(country_code: "CA").count).to eq(0)
    end
  end

  describe ".dump (round-trip)" do
    let(:company) { create(:company) }

    it "serializes AU rules back to paste format" do
      described_class.new(company: company, country: "AU", text: "1: 1000-1935, 2158\n2: 2080-2084").call
      rules = company.shipping_zone_postal_rules.where(country_code: "AU").to_a
      expect(described_class.dump(country: "AU", rules: rules)).to eq("1: 1000-1935, 2158\n2: 2080-2084")
    end

    it "serializes CA rules back (FSA vs full token)" do
      described_class.new(company: company, country: "CA", text: "G0A4V0,1\nV9N,2").call
      rules = company.shipping_zone_postal_rules.where(country_code: "CA").to_a
      expect(described_class.dump(country: "CA", rules: rules)).to eq("G0A4V0,1\nV9N,2")
    end

    it "round-trips: dump then re-import yields identical rules" do
      described_class.new(company: company, country: "AU", text: "1: 1000-1935, 2000-2079\n2: 2080-2084").call
      before = company.shipping_zone_postal_rules.where(country_code: "AU").pluck(:zone, :postal_start, :postal_end).sort
      dumped = described_class.dump(country: "AU", rules: company.shipping_zone_postal_rules.where(country_code: "AU").to_a)
      described_class.new(company: company, country: "AU", text: dumped).call
      after = company.shipping_zone_postal_rules.where(country_code: "AU").pluck(:zone, :postal_start, :postal_end).sort
      expect(after).to eq(before)
    end
  end
end
