require "rails_helper"

RSpec.describe AdAccountsHelper, type: :helper do
  describe "#ad_account_status_key" do
    it "maps known Meta account_status integers to keys" do
      expect(helper.ad_account_status_key(1)).to eq(:active)
      expect(helper.ad_account_status_key(2)).to eq(:disabled)
      expect(helper.ad_account_status_key(3)).to eq(:unsettled)
      expect(helper.ad_account_status_key(7)).to eq(:pending_risk_review)
      expect(helper.ad_account_status_key(101)).to eq(:closed)
      expect(helper.ad_account_status_key(201)).to eq(:active)
    end

    it "falls back to :unknown for unmapped or nil statuses" do
      expect(helper.ad_account_status_key(999)).to eq(:unknown)
      expect(helper.ad_account_status_key(nil)).to eq(:unknown)
    end
  end

  describe "#ad_account_active?" do
    it "is true only for active statuses (1 and 201)" do
      expect(helper.ad_account_active?(1)).to be(true)
      expect(helper.ad_account_active?(201)).to be(true)
    end

    it "is false for restricted / disabled / unknown / nil statuses" do
      expect(helper.ad_account_active?(2)).to be(false)
      expect(helper.ad_account_active?(3)).to be(false)
      expect(helper.ad_account_active?(999)).to be(false)
      expect(helper.ad_account_active?(nil)).to be(false)
    end
  end
end
