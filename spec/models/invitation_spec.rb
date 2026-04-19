require "rails_helper"

RSpec.describe Invitation, type: :model do
  describe "validations" do
    it "requires email" do
      invitation = build(:invitation, email: nil)
      expect(invitation).not_to be_valid
    end

    it "validates email format" do
      invitation = build(:invitation, email: "invalid")
      expect(invitation).not_to be_valid
    end

    it "rejects duplicate pending invitation for same company and email" do
      existing = create(:invitation)
      duplicate = build(:invitation, company: existing.company, email: existing.email)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:email]).to be_present
    end

    it "allows re-inviting after previous invitation was accepted" do
      existing = create(:invitation)
      existing.accept!(create(:user))
      new_inv = build(:invitation, company: existing.company, email: existing.email)
      expect(new_inv).to be_valid
    end

    it "auto-generates a token" do
      invitation = build(:invitation)
      invitation.valid?
      expect(invitation.token).to be_present
    end
  end

  describe "#accept!" do
    it "creates a membership and sets accepted_at" do
      user = create(:user)
      invitation = create(:invitation, role: :member, permissions: %w[orders tickets])

      expect { invitation.accept!(user) }.to change(Membership, :count).by(1)

      expect(invitation.reload.accepted_at).to be_present
      membership = user.membership_for(invitation.company)
      expect(membership.role).to eq("member")
      expect(membership.permissions).to eq(%w[orders tickets])
    end
  end

  describe "scopes" do
    it "returns only pending invitations" do
      pending_inv = create(:invitation)
      accepted_inv = create(:invitation)
      accepted_inv.accept!(create(:user))

      expect(Invitation.pending).to include(pending_inv)
      expect(Invitation.pending).not_to include(accepted_inv)
    end
  end

  describe "#accepted?" do
    it "returns false for pending invitations" do
      invitation = create(:invitation)
      expect(invitation.accepted?).to be false
    end

    it "returns true for accepted invitations" do
      invitation = create(:invitation)
      invitation.accept!(create(:user))
      expect(invitation.accepted?).to be true
    end
  end

  describe "group assignment rules" do
    let(:company) { create(:company) }
    let(:invited_by) { create(:user) }

    it "rejects an owner invitation with a group" do
      group = create(:group, company: company)
      invitation = build(:invitation, company: company, invited_by: invited_by, role: :owner, group: group)
      expect(invitation).not_to be_valid
      expect(invitation.errors[:group_id]).to be_present
    end

    it "allows a member invitation with no group when the company has no groups" do
      invitation = build(:invitation, company: company, invited_by: invited_by, role: :member, group: nil)
      expect(invitation).to be_valid
    end

    it "rejects a member invitation with no group when the company has at least one group" do
      create(:group, company: company)
      invitation = build(:invitation, company: company, invited_by: invited_by, role: :member, group: nil)
      expect(invitation).not_to be_valid
      expect(invitation.errors[:group_id]).to be_present
    end

    it "rejects a group from a different company" do
      other_group = create(:group, company: create(:company))
      invitation = build(:invitation, company: company, invited_by: invited_by, role: :member, group: other_group)
      expect(invitation).not_to be_valid
      expect(invitation.errors[:group_id]).to be_present
    end
  end

  describe "#accept! with group" do
    it "propagates the group to the created membership for a member invitation" do
      company = create(:company)
      group = create(:group, company: company)
      invitation = create(:invitation, company: company, role: :member, permissions: %w[orders], group: group)
      user = create(:user)

      invitation.accept!(user)

      membership = user.membership_for(company)
      expect(membership).to be_member
      expect(membership.group).to eq(group)
    end

    it "ignores group on an owner invitation" do
      company = create(:company)
      invitation = create(:invitation, company: company, role: :owner, permissions: [], group: nil)
      user = create(:user)

      invitation.accept!(user)

      membership = user.membership_for(company)
      expect(membership).to be_owner
      expect(membership.group).to be_nil
    end
  end
end
