require "rails_helper"

RSpec.describe TimezoneResolver do
  describe ".resolve" do
    it "returns timezone for known country code" do
      expect(described_class.resolve("US")).to eq("America/New_York")
      expect(described_class.resolve("CN")).to eq("Asia/Shanghai")
      expect(described_class.resolve("JP")).to eq("Asia/Tokyo")
      expect(described_class.resolve("GB")).to eq("Europe/London")
    end

    it "is case-insensitive" do
      expect(described_class.resolve("us")).to eq("America/New_York")
    end

    it "returns UTC for unknown country code" do
      expect(described_class.resolve("XX")).to eq("UTC")
    end

    it "returns UTC for blank input" do
      expect(described_class.resolve(nil)).to eq("UTC")
      expect(described_class.resolve("")).to eq("UTC")
    end
  end
end
