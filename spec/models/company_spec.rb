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
end
