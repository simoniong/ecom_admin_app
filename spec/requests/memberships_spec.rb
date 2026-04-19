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

  describe "PATCH /memberships/:id group and role changes" do
    let(:group_a) { create(:group, company: company, name: "Sales") }
    let(:group_b) { create(:group, company: company, name: "Support") }

    it "moves a member from one group to another" do
      member_membership.update!(group: group_a)
      patch membership_path(id: member_membership.id), params: {
        membership: { role: "member", group_id: group_b.id, permissions: %w[orders] }
      }
      expect(response).to redirect_to(invitations_path)
      expect(member_membership.reload.group).to eq(group_b)
    end

    it "promotes a member to owner and clears the group" do
      member_membership.update!(group: group_a)
      patch membership_path(id: member_membership.id), params: {
        membership: { role: "owner", group_id: group_b.id }
      }
      expect(response).to redirect_to(invitations_path)
      expect(member_membership.reload).to be_owner
      expect(member_membership.group).to be_nil
    end

    it "demotes an owner to a member with a group assigned" do
      other_owner_user = create(:user)
      other_owner = create(:membership, company: company, user: other_owner_user, role: :owner)

      patch membership_path(id: other_owner.id), params: {
        membership: { role: "member", group_id: group_a.id, permissions: %w[orders] }
      }
      expect(response).to redirect_to(invitations_path)
      expect(other_owner.reload).to be_member
      expect(other_owner.group).to eq(group_a)
    end

    it "rejects a member update without a group when company has groups" do
      _ = group_a # ensure group exists
      member_membership.update!(group: create(:group, company: company))
      patch membership_path(id: member_membership.id), params: {
        membership: { role: "member", group_id: "", permissions: %w[orders] }
      }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "leaves resources behind when a user is moved between groups" do
      member_membership.update!(group: group_a)
      store = create(:shopify_store, company: company, user: member_user, group: group_a)

      patch membership_path(id: member_membership.id), params: {
        membership: { role: "member", group_id: group_b.id, permissions: %w[shopify_stores] }
      }

      expect(store.reload.group).to eq(group_a)
      expect(member_membership.reload.group).to eq(group_b)
    end
  end
end
