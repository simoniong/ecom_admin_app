require "rails_helper"

RSpec.describe Company, type: :model do
  describe "validations" do
    it "requires a name" do
      company = Company.new(name: nil)
      expect(company).not_to be_valid
      expect(company.errors[:name]).to include("can't be blank")
    end

    it "is valid with a name" do
      company = Company.new(name: "Test Company")
      expect(company).to be_valid
    end
  end

  describe "associations" do
    it "has many memberships" do
      company = create(:company)
      user = create(:user)
      create(:membership, company: company, user: user, role: :member)
      expect(company.memberships.count).to eq(1)
    end

    it "has many users through memberships" do
      company = create(:company)
      user = create(:user)
      create(:membership, company: company, user: user, role: :member)
      expect(company.users).to include(user)
    end

    it "has many shopify_stores" do
      user = create(:user)
      company = user.companies.first
      store = create(:shopify_store, user: user, company: company)
      expect(company.shopify_stores).to include(store)
    end

    it "has many ad_accounts" do
      user = create(:user)
      company = user.companies.first
      account = create(:ad_account, user: user, company: company)
      expect(company.ad_accounts).to include(account)
    end

    it "has many email_accounts" do
      user = create(:user)
      company = user.companies.first
      account = create(:email_account, user: user, company: company)
      expect(company.email_accounts).to include(account)
    end

    it "has many invitations" do
      company = create(:company)
      user = create(:user)
      invitation = create(:invitation, company: company, invited_by: user)
      expect(company.invitations).to include(invitation)
    end
  end

  let(:valid_key) { "A" * 32 }

  describe "#tracking_api_key_configured?" do
    it "returns true when tracking_api_key is set" do
      company = create(:company, tracking_api_key: valid_key, tracking_mode: "new_only", tracking_starts_at: Time.current)
      expect(company.tracking_api_key_configured?).to be(true)
    end

    it "returns false when tracking_api_key is blank" do
      expect(create(:company, tracking_api_key: nil).tracking_api_key_configured?).to be(false)
      expect(create(:company, tracking_api_key: "").tracking_api_key_configured?).to be(false)
    end
  end

  describe "#tracking_enabled?" do
    it "reflects the column value" do
      expect(build(:company).tracking_enabled?).to be(false)
      expect(build(:company, tracking_enabled: true, tracking_api_key: valid_key, tracking_mode: "new_only", tracking_starts_at: Time.current).tracking_enabled?).to be(true)
    end
  end

  describe ".tracking_active scope" do
    it "returns only companies with tracking_enabled = true" do
      active = create(:company, tracking_enabled: true, tracking_api_key: valid_key, tracking_mode: "new_only", tracking_starts_at: Time.current)
      create(:company)

      expect(Company.tracking_active).to contain_exactly(active)
    end
  end

  describe "tracking_api_key format validation" do
    it "accepts a 32-character alphanumeric key" do
      company = build(:company,
                      tracking_enabled: true,
                      tracking_api_key: valid_key,
                      tracking_mode: "new_only",
                      tracking_starts_at: Time.current)
      expect(company).to be_valid
    end

    it "rejects keys shorter than 32 characters" do
      company = build(:company,
                      tracking_enabled: true,
                      tracking_api_key: "short-key",
                      tracking_mode: "new_only",
                      tracking_starts_at: Time.current)
      expect(company).not_to be_valid
      expect(company.errors[:tracking_api_key]).to be_present
    end

    it "rejects keys with non-alphanumeric characters" do
      company = build(:company,
                      tracking_enabled: true,
                      tracking_api_key: "!" * 32,
                      tracking_mode: "new_only",
                      tracking_starts_at: Time.current)
      expect(company).not_to be_valid
      expect(company.errors[:tracking_api_key]).to be_present
    end
  end

  describe "tracking_api_key_required_when_enabled validation" do
    it "rejects enabling without an api key" do
      company = build(:company, tracking_enabled: true)
      expect(company).not_to be_valid
      expect(company.errors[:tracking_api_key]).to be_present
    end

    it "allows enabling when api key and mode are set" do
      company = build(:company,
                      tracking_enabled: true,
                      tracking_api_key: valid_key,
                      tracking_mode: "new_only",
                      tracking_starts_at: Time.current)
      expect(company).to be_valid
    end

    it "allows disabled state with no config" do
      expect(build(:company, tracking_enabled: false)).to be_valid
    end

    it "preserves existing config in disabled state" do
      company = build(:company,
                      tracking_enabled: false,
                      tracking_api_key: valid_key,
                      tracking_mode: "backfill",
                      tracking_backfill_days: 30,
                      tracking_starts_at: 30.days.ago)
      expect(company).to be_valid
    end
  end

  describe ".starts_at_for" do
    it "returns now for new_only" do
      now = Time.current
      expect(Company.starts_at_for(mode: "new_only", now: now)).to eq(now)
    end

    it "returns now - days.days for backfill with explicit days" do
      now = Time.current
      expect(Company.starts_at_for(mode: "backfill", days: 45, now: now)).to eq(now - 45.days)
    end

    it "returns nil for backfill with nil days (all history)" do
      expect(Company.starts_at_for(mode: "backfill", days: nil)).to be_nil
    end

    it "returns nil for unknown mode" do
      expect(Company.starts_at_for(mode: "bogus")).to be_nil
      expect(Company.starts_at_for(mode: nil)).to be_nil
    end
  end

  describe "#tracking_all_history?" do
    it "is true only in backfill mode with nil days" do
      expect(build(:company, tracking_mode: "backfill", tracking_backfill_days: nil).tracking_all_history?).to be(true)
      expect(build(:company, tracking_mode: "backfill", tracking_backfill_days: 30).tracking_all_history?).to be(false)
      expect(build(:company, tracking_mode: "new_only", tracking_backfill_days: nil).tracking_all_history?).to be(false)
    end
  end

  describe "tracking_mode validation" do
    it "rejects an unknown tracking_mode value" do
      company = build(:company, tracking_mode: "bogus")
      expect(company).not_to be_valid
      expect(company.errors[:tracking_mode]).to be_present
    end

    it "requires tracking_mode when api key is set" do
      company = build(:company, tracking_api_key: valid_key, tracking_mode: nil)
      expect(company).not_to be_valid
      expect(company.errors[:tracking_mode]).to be_present
    end

    it "rejects tracking_mode when api key is blank" do
      company = build(:company, tracking_api_key: nil, tracking_mode: "new_only")
      expect(company).not_to be_valid
      expect(company.errors[:tracking_mode]).to be_present
    end

    it "accepts valid mode with api key" do
      company = build(:company, tracking_api_key: valid_key, tracking_mode: "backfill", tracking_backfill_days: 30, tracking_starts_at: 30.days.ago)
      expect(company).to be_valid
    end
  end

  describe "tracking_backfill_days validation" do
    it "rejects zero or negative values" do
      company = build(:company, tracking_api_key: valid_key, tracking_mode: "backfill", tracking_backfill_days: 0, tracking_starts_at: Time.current)
      expect(company).not_to be_valid
      expect(company.errors[:tracking_backfill_days]).to be_present
    end

    it "rejects days when mode is new_only" do
      company = build(:company, tracking_api_key: valid_key, tracking_mode: "new_only", tracking_backfill_days: 10, tracking_starts_at: Time.current)
      expect(company).not_to be_valid
      expect(company.errors[:tracking_backfill_days]).to be_present
    end

    it "accepts nil days in backfill mode (all history)" do
      company = build(:company, tracking_api_key: valid_key, tracking_mode: "backfill", tracking_backfill_days: nil, tracking_starts_at: nil)
      expect(company).to be_valid
    end
  end

  describe "tracking_api_key encryption" do
    it "encrypts the value at rest" do
      secret = "S" * 32
      company = create(:company, tracking_api_key: secret, tracking_mode: "new_only", tracking_starts_at: Time.current)
      raw = Company.connection.select_value(
        Company.sanitize_sql_array([ "SELECT tracking_api_key FROM companies WHERE id = ?", company.id ])
      )
      expect(raw).not_to include(secret)
      expect(company.reload.tracking_api_key).to eq(secret)
    end
  end
end
