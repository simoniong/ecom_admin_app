require "rails_helper"

RSpec.describe FulfillmentService do
  describe ".for" do
    it "returns the Raydo adapter for a raydo account" do
      account = build(:logistics_account, provider: "raydo")
      expect(described_class.for(account)).to be_a(FulfillmentService::Raydo)
    end

    it "raises UnknownProvider for an unregistered provider" do
      account = build(:logistics_account, provider: "raydo")
      account.provider = "renyimen"
      expect { described_class.for(account) }
        .to raise_error(FulfillmentService::UnknownProvider)
    end

    it "UnknownProvider is a FulfillmentService::Error (so controllers' rescue catches it)" do
      expect(FulfillmentService::UnknownProvider.ancestors).to include(FulfillmentService::Error)
    end
  end
end
