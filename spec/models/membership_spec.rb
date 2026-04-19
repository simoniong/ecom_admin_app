require "rails_helper"

RSpec.describe Membership, type: :model do
  describe "validations" do
    it "requires uniqueness of company_id scoped to user_id" do
      user = create(:user)
      company = user.companies.first
      # User already has owner membership from factory
      duplicate = Membership.new(company: company, user: user, role: :member)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:company_id]).to be_present
    end

    it "allows the same user in different companies" do
      user = create(:user)
      other_company = create(:company)
      membership = Membership.new(company: other_company, user: user, role: :member, permissions: %w[dashboard])
      expect(membership).to be_valid
    end
  end

  describe "#has_permission?" do
    let(:user) { create(:user) }
    let(:company) { user.companies.first }

    it "returns true for owner regardless of permissions" do
      membership = user.membership_for(company)
      expect(membership).to be_owner
      expect(membership.has_permission?("orders")).to be true
      expect(membership.has_permission?("tickets")).to be true
    end

    it "returns true for member with matching permission" do
      other_company = create(:company)
      membership = create(:membership, company: other_company, user: user, role: :member, permissions: %w[orders])
      expect(membership.has_permission?("orders")).to be true
    end

    it "always grants dashboard permission to members" do
      other_company = create(:company)
      membership = create(:membership, company: other_company, user: user, role: :member, permissions: %w[orders])
      expect(membership.has_permission?("dashboard")).to be true
    end

    it "returns false for member without matching permission" do
      other_company = create(:company)
      membership = create(:membership, company: other_company, user: user, role: :member, permissions: %w[orders])
      expect(membership.has_permission?("tickets")).to be false
      expect(membership.has_permission?("ad_campaigns")).to be false
    end
  end

  describe "roles" do
    it "supports member and owner roles" do
      expect(Membership.roles).to eq("member" => 0, "owner" => 1)
    end
  end

  describe "group assignment rules" do
    let(:company) { create(:company) }
    let(:user) { create(:user) }

    it "allows an owner with no group" do
      membership = Membership.new(company: company, user: user, role: :owner, group: nil)
      expect(membership).to be_valid
    end

    it "rejects an owner with a group assigned" do
      group = create(:group, company: company)
      membership = Membership.new(company: company, user: user, role: :owner, group: group)
      expect(membership).not_to be_valid
      expect(membership.errors[:group_id]).to be_present
    end

    it "allows a member with no group when the company has no groups" do
      membership = Membership.new(company: company, user: user, role: :member, permissions: %w[orders])
      expect(membership).to be_valid
    end

    it "rejects a member with no group when the company has at least one group" do
      create(:group, company: company)
      membership = Membership.new(company: company, user: user, role: :member, permissions: %w[orders], group: nil)
      expect(membership).not_to be_valid
      expect(membership.errors[:group_id]).to be_present
    end

    it "accepts a member assigned to a group belonging to the same company" do
      group = create(:group, company: company)
      membership = Membership.new(company: company, user: user, role: :member, permissions: %w[orders], group: group)
      expect(membership).to be_valid
    end
  end
end
