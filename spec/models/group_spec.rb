require "rails_helper"

RSpec.describe Group, type: :model do
  describe "associations" do
    let(:group) { create(:group) }

    it "belongs to a company" do
      expect(group.company).to be_a(Company)
    end

    it "has many memberships" do
      expect(group).to respond_to(:memberships)
    end

    it "has many users through memberships" do
      expect(group).to respond_to(:users)
    end

    it "has many shopify_stores" do
      expect(group).to respond_to(:shopify_stores)
    end

    it "has many ad_accounts" do
      expect(group).to respond_to(:ad_accounts)
    end

    it "has many email_accounts" do
      expect(group).to respond_to(:email_accounts)
    end

    it "has many invitations" do
      expect(group).to respond_to(:invitations)
    end
  end

  describe "validations" do
    it "requires a name" do
      group = build(:group, name: nil)
      expect(group).not_to be_valid
      expect(group.errors[:name]).to be_present
    end

    it "requires name to be unique within a company (case insensitive)" do
      company = create(:company)
      create(:group, company: company, name: "Sales")
      duplicate = build(:group, company: company, name: "sales")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to be_present
    end

    it "allows the same name across different companies" do
      create(:group, company: create(:company), name: "Sales")
      other = build(:group, company: create(:company), name: "Sales")
      expect(other).to be_valid
    end
  end
end
