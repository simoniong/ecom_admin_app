require "rails_helper"

RSpec.describe CarrierCatalog do
  let(:path) { Rails.root.join("spec/fixtures/files/17track_carriers.json") }
  subject(:catalog) { described_class.new(path: path) }

  describe "#all" do
    it "returns the parsed carrier entries" do
      expect(catalog.all).to include({ "code" => 21051, "name" => "USPS", "country" => "US" })
      expect(catalog.all.size).to eq(3)
    end
  end

  describe "#valid?" do
    it "is true for a known code (int or string)" do
      expect(catalog.valid?(21051)).to be(true)
      expect(catalog.valid?("3011")).to be(true)
    end

    it "is false for an unknown code" do
      expect(catalog.valid?(99999)).to be(false)
    end
  end

  describe "#name_for" do
    it "returns the carrier name" do
      expect(catalog.name_for(3013)).to eq("China EMS")
    end

    it "returns nil for unknown" do
      expect(catalog.name_for(1)).to be_nil
    end
  end

  describe "missing file" do
    it "returns an empty list instead of raising" do
      empty = described_class.new(path: Rails.root.join("tmp/does_not_exist.json"))
      expect(empty.all).to eq([])
      expect(empty.valid?(21051)).to be(false)
    end
  end

  describe "invalid JSON file" do
    it "returns an empty list instead of raising" do
      bad = described_class.new(path: Rails.root.join("spec/fixtures/files/bad_carriers.json"))
      expect(bad.all).to eq([])
    end
  end

  describe ".default" do
    after { described_class.reset! }

    it "returns the same instance across calls" do
      expect(described_class.default).to be(described_class.default)
    end

    it "is cleared by .reset!" do
      first = described_class.default
      described_class.reset!
      expect(described_class.default).not_to be(first)
    end
  end
end
