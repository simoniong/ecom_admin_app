require "rails_helper"

RSpec.describe AdAccount, type: :model do
  let(:user) { create(:user) }
  let(:ad_account) { create(:ad_account, user: user, access_token: "my-meta-token") }

  it "is valid with valid attributes" do
    expect(ad_account).to be_valid
  end

  it "generates a UUID id" do
    expect(ad_account.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  it "belongs to user" do
    expect(ad_account.user).to eq(user)
  end

  it "requires user" do
    account = build(:ad_account, user: nil)
    expect(account).not_to be_valid
  end

  it "requires platform" do
    ad_account.platform = ""
    expect(ad_account).not_to be_valid
  end

  it "validates platform inclusion" do
    ad_account.platform = "invalid"
    expect(ad_account).not_to be_valid
  end

  it "requires account_id" do
    ad_account.account_id = ""
    expect(ad_account).not_to be_valid
  end

  it "enforces account_id uniqueness scoped to platform and user" do
    duplicate = build(:ad_account, user: user, platform: ad_account.platform, account_id: ad_account.account_id)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:account_id]).to include("has already been taken")
  end

  it "allows same account_id for different users" do
    other_user = create(:user)
    other_account = build(:ad_account, user: other_user, platform: ad_account.platform, account_id: ad_account.account_id)
    expect(other_account).to be_valid
  end

  it "requires access_token" do
    ad_account.access_token = ""
    expect(ad_account).not_to be_valid
  end

  it "encrypts access_token in database" do
    connection = ActiveRecord::Base.connection
    raw_value = connection.select_value(
      "SELECT access_token FROM ad_accounts WHERE id = #{connection.quote(ad_account.id)}"
    )
    expect(raw_value).not_to eq("my-meta-token")
  end

  describe ".meta scope" do
    it "returns only meta accounts" do
      create(:ad_account, user: user)
      expect(described_class.meta.count).to eq(1)
    end
  end

  describe "#token_expired?" do
    it "returns true when token has expired" do
      ad_account.token_expires_at = 1.day.ago
      expect(ad_account.token_expired?).to be true
    end

    it "returns false when token is still valid" do
      ad_account.token_expires_at = 1.day.from_now
      expect(ad_account.token_expired?).to be false
    end

    it "returns false when token_expires_at is nil" do
      ad_account.token_expires_at = nil
      expect(ad_account.token_expired?).to be false
    end
  end

  describe "#token_expiring_soon?" do
    it "returns true when token expires within 7 days" do
      ad_account.token_expires_at = 3.days.from_now
      expect(ad_account.token_expiring_soon?).to be true
    end

    it "returns false when token expires beyond 7 days" do
      ad_account.token_expires_at = 30.days.from_now
      expect(ad_account.token_expiring_soon?).to be false
    end

    it "returns false when token_expires_at is nil" do
      ad_account.token_expires_at = nil
      expect(ad_account.token_expiring_soon?).to be false
    end
  end

  describe "associations" do
    it "has many ad_daily_metrics" do
      metric = create(:ad_daily_metric, ad_account: ad_account)
      expect(ad_account.ad_daily_metrics).to include(metric)
    end

    it "destroys associated metrics on destroy" do
      create(:ad_daily_metric, ad_account: ad_account)
      expect { ad_account.destroy }.to change(AdDailyMetric, :count).by(-1)
    end

    it "optionally belongs to shopify_store" do
      expect(build(:ad_account, user: user, shopify_store: nil)).to be_valid
    end

    it "can be linked to a shopify_store" do
      store = create(:shopify_store, user: user)
      ad_account.update!(shopify_store: store)
      expect(ad_account.reload.shopify_store).to eq(store)
    end
  end
end
