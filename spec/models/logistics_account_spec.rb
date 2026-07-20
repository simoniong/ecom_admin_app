require "rails_helper"

RSpec.describe LogisticsAccount, type: :model do
  let(:company) { create(:company) }
  let(:account) { create(:logistics_account, company: company, password: "123456") }

  it "is valid with valid attributes" do
    expect(account).to be_valid
  end

  it "generates a UUID id" do
    expect(account.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  it "belongs to company" do
    expect(account.company).to eq(company)
  end

  describe "password encryption" do
    it "round-trips the plaintext password through the model" do
      expect(account.reload.password).to eq("123456")
    end

    it "does not store the plaintext password in the database" do
      raw_value = LogisticsAccount.connection.select_value(
        "SELECT password FROM logistics_accounts WHERE id = '#{account.id}'"
      )
      expect(raw_value).not_to eq("123456")
    end
  end

  describe "provider" do
    it "requires provider" do
      account.provider = nil
      expect(account).not_to be_valid
    end

    it "rejects providers outside the allowed list" do
      account.provider = "not_a_real_provider"
      expect(account).not_to be_valid
    end

    it "accepts raydo" do
      account.provider = "raydo"
      expect(account).to be_valid
    end

    it "enforces provider uniqueness scoped to company" do
      duplicate = build(:logistics_account, company: company, provider: account.provider)
      expect(duplicate).not_to be_valid
    end

    it "allows the same provider for a different company" do
      other_company = create(:company)
      duplicate = build(:logistics_account, company: other_company, provider: account.provider)
      expect(duplicate).to be_valid
    end
  end

  describe "url1_base / url2_base" do
    it "accepts a blank url1_base and url2_base (account may exist before URLs are entered)" do
      account.url1_base = ""
      account.url2_base = ""
      expect(account).to be_valid
    end

    it "accepts a valid http(s) URL" do
      account.url1_base = "http://raydo.example.com:8082"
      account.url2_base = "https://raydo.example.com:8089"
      expect(account).to be_valid
    end

    it "rejects a url1_base that is not a valid URL" do
      account.url1_base = "not a url"
      expect(account).not_to be_valid
      expect(account.errors[:url1_base]).to be_present
    end

    it "rejects a url2_base that is not a valid URL" do
      account.url2_base = "not a url"
      expect(account).not_to be_valid
      expect(account.errors[:url2_base]).to be_present
    end
  end

  describe "associations" do
    it "has many logistics_channels" do
      channel = create(:logistics_channel, logistics_account: account)
      expect(account.logistics_channels).to include(channel)
    end

    it "destroys logistics_channels when destroyed" do
      channel = create(:logistics_channel, logistics_account: account)
      account.destroy
      expect(LogisticsChannel.exists?(channel.id)).to be false
    end
  end
end
