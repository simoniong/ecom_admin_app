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
end
