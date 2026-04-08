require "rails_helper"

RSpec.describe "Memberships", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }
  let(:member_user) { create(:user) }
  let!(:member_membership) do
    create(:membership, company: company, user: member_user, role: :member, permissions: %w[orders tickets])
  end

  before do
    sign_in owner
  end

  describe "GET /memberships/:id/edit" do
    it "renders edit page for a member" do
      get edit_membership_path(id: member_membership.id)
      expect(response).to have_http_status(:success)
    end

    it "redirects when trying to edit own membership" do
      owner_membership = owner.membership_for(company)
      get edit_membership_path(id: owner_membership.id)
      expect(response).to redirect_to(invitations_path)
    end

    it "redirects non-owner users" do
      sign_in member_user
      patch switch_company_path(id: company.id)
      get edit_membership_path(id: member_membership.id)
      expect(response).to redirect_to(authenticated_root_path)
    end
  end

  describe "PATCH /memberships/:id" do
    it "updates permissions" do
      patch membership_path(id: member_membership.id), params: {
        membership: { permissions: %w[orders shipments ad_campaigns] }
      }
      expect(response).to redirect_to(invitations_path)
      expect(member_membership.reload.permissions).to eq(%w[orders shipments ad_campaigns])
    end

    it "clears all permissions when the form submits a blank hidden value" do
      patch membership_path(id: member_membership.id), params: {
        membership: { permissions: [ "" ] }
      }
      expect(response).to redirect_to(invitations_path)
      expect(member_membership.reload.permissions).to eq([])
    end

    it "clears all permissions when no membership param is sent" do
      patch membership_path(id: member_membership.id), params: {}
      expect(response).to redirect_to(invitations_path)
      expect(member_membership.reload.permissions).to eq([])
    end

    it "filters out invalid permission values" do
      patch membership_path(id: member_membership.id), params: {
        membership: { permissions: %w[orders hacked_permission tickets] }
      }
      expect(response).to redirect_to(invitations_path)
      expect(member_membership.reload.permissions).to eq(%w[orders tickets])
    end

    it "prevents updating own membership" do
      owner_membership = owner.membership_for(company)
      patch membership_path(id: owner_membership.id), params: {
        membership: { permissions: %w[orders] }
      }
      expect(response).to redirect_to(invitations_path)
      expect(owner_membership.reload.permissions).to eq([])
    end
  end

  describe "DELETE /memberships/:id" do
    it "removes a member from the company" do
      expect {
        delete membership_path(id: member_membership.id)
      }.to change(Membership, :count).by(-1)
      expect(response).to redirect_to(invitations_path)
    end

    it "does not delete the user account" do
      expect {
        delete membership_path(id: member_membership.id)
      }.not_to change(User, :count)
    end

    it "prevents removing own membership" do
      owner_membership = owner.membership_for(company)
      expect {
        delete membership_path(id: owner_membership.id)
      }.not_to change(Membership, :count)
      expect(response).to redirect_to(invitations_path)
    end

    it "prevents removing another owner's membership" do
      other_owner_user = create(:user)
      other_owner_membership = create(:membership, company: company, user: other_owner_user, role: :owner)
      expect {
        delete membership_path(id: other_owner_membership.id)
      }.not_to change(Membership, :count)
      expect(response).to redirect_to(invitations_path)
    end

    it "blocks non-owner from removing members" do
      sign_in member_user
      patch switch_company_path(id: company.id)

      other_member = create(:user)
      other_membership = create(:membership, company: company, user: other_member, role: :member, permissions: %w[orders])

      expect {
        delete membership_path(id: other_membership.id)
      }.not_to change(Membership, :count)
      expect(response).to redirect_to(authenticated_root_path)
    end
  end
end
