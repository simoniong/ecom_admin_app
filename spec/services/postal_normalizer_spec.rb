require "rails_helper"

RSpec.describe PostalNormalizer do
  describe ".normalize (lookup key)" do
    it "zero-pads AU to 4 digits" do
      expect(described_class.normalize("AU", "200")).to eq("0200")
      expect(described_class.normalize("AU", "2158")).to eq("2158")
      expect(described_class.normalize("AU", " 2075 ")).to eq("2075")
    end

    it "rejects bad AU postals" do
      expect(described_class.normalize("AU", "12345")).to be_nil
      expect(described_class.normalize("AU", "AB")).to be_nil
      expect(described_class.normalize("AU", "")).to be_nil
    end

    it "normalizes CA to 6 chars, padding FSA-only with 000" do
      expect(described_class.normalize("CA", "g0a 4v0")).to eq("G0A4V0")
      expect(described_class.normalize("CA", "G0A")).to eq("G0A000")
    end

    it "rejects bad CA postals" do
      expect(described_class.normalize("CA", "G0A4")).to be_nil
      expect(described_class.normalize("CA", "")).to be_nil
    end

    it "returns nil for countries with no postal map" do
      expect(described_class.normalize("US", "90210")).to be_nil
    end
  end

  describe ".range_for (rule endpoints)" do
    it "expands AU ranges and singles" do
      expect(described_class.range_for("AU", "1000-1935")).to eq(%w[1000 1935])
      expect(described_class.range_for("AU", "2158")).to eq(%w[2158 2158])
      expect(described_class.range_for("AU", "200-299")).to eq(%w[0200 0299])
    end

    it "rejects inverted / bad AU ranges" do
      expect(described_class.range_for("AU", "1935-1000")).to be_nil
      expect(described_class.range_for("AU", "abc")).to be_nil
    end

    it "expands CA FSA (3) and sub-range (6) tokens to the FSA's ZZZ ceiling" do
      expect(described_class.range_for("CA", "V9N")).to eq(%w[V9N000 V9NZZZ])
      expect(described_class.range_for("CA", "G0A4V0")).to eq(%w[G0A4V0 G0AZZZ])
    end

    it "rejects bad CA tokens" do
      expect(described_class.range_for("CA", "G0A4")).to be_nil
    end
  end
end
