require "rails_helper"

RSpec.describe "Groups", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }

  describe "GET /groups" do
    it "returns success for owner" do
      sign_in owner
      get groups_path
      expect(response).to have_http_status(:success)
    end

    it "redirects a member away" do
      member = create(:user)
      create(:membership, company: company, user: member, role: :member, permissions: %w[dashboard])
      sign_in member
      patch switch_company_path(id: company.id)

      get groups_path

      expect(response).to redirect_to(authenticated_root_path)
    end
  end

  describe "GET /groups/new" do
    it "returns success for owner" do
      sign_in owner
      get new_group_path
      expect(response).to have_http_status(:success)
    end
  end

  describe "POST /groups" do
    it "creates a group" do
      sign_in owner
      expect {
        post groups_path, params: { group: { name: "Sales", description: "Sales team" } }
      }.to change { company.groups.count }.by(1)

      expect(response).to redirect_to(groups_path)
      expect(company.groups.last.name).to eq("Sales")
    end

    it "rejects a blank name" do
      sign_in owner
      post groups_path, params: { group: { name: "" } }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects a duplicate name within the same company" do
      sign_in owner
      create(:group, company: company, name: "Sales")
      post groups_path, params: { group: { name: "sales" } }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "backfills existing members and resources when creating the first group" do
      member_user = create(:user)
      create(:membership, company: company, user: member_user, role: :member, permissions: %w[orders])
      store = create(:shopify_store, company: company, user: owner)

      sign_in owner
      post groups_path, params: { group: { name: "Sales" } }

      expect(response).to redirect_to(groups_path)
      group = company.groups.find_by(name: "Sales")
      expect(member_user.membership_for(company).reload.group).to eq(group)
      expect(store.reload.group).to eq(group)
    end

    it "does not backfill when creating a second group" do
      existing = create(:group, company: company, name: "Sales")
      store = create(:shopify_store, company: company, user: owner, group: existing)

      sign_in owner
      post groups_path, params: { group: { name: "Support" } }

      expect(response).to redirect_to(groups_path)
      second_group = company.groups.find_by(name: "Support")
      expect(store.reload.group).to eq(existing)
      expect(second_group.shopify_stores.count).to eq(0)
    end
  end

  describe "GET /groups/:id/edit" do
    it "returns success for the group's company owner" do
      group = create(:group, company: company, name: "Sales")
      sign_in owner
      get edit_group_path(id: group.id)
      expect(response).to have_http_status(:success)
    end

    it "404s for a group in another company" do
      other_group = create(:group, company: create(:company))
      sign_in owner
      get edit_group_path(id: other_group.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /groups/:id" do
    it "updates a group" do
      group = create(:group, company: company, name: "Sales")
      sign_in owner
      patch group_path(id: group.id), params: { group: { name: "Customer Success" } }
      expect(response).to redirect_to(groups_path)
      expect(group.reload.name).to eq("Customer Success")
    end

    it "rejects a blank name" do
      group = create(:group, company: company, name: "Sales")
      sign_in owner
      patch group_path(id: group.id), params: { group: { name: "" } }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "DELETE /groups/:id" do
    it "destroys an empty group" do
      group = create(:group, company: company)
      sign_in owner
      expect {
        delete group_path(id: group.id)
      }.to change { company.groups.count }.by(-1)
    end

    it "refuses when memberships still reference the group" do
      group = create(:group, company: company)
      member_user = create(:user)
      create(:membership, company: company, user: member_user, role: :member, permissions: %w[dashboard], group: group)

      sign_in owner
      expect {
        delete group_path(id: group.id)
      }.not_to change { company.groups.count }
      expect(response).to redirect_to(groups_path)
      expect(flash[:alert]).to be_present
    end

    it "refuses when Shopify stores still reference the group" do
      group = create(:group, company: company)
      create(:shopify_store, company: company, user: owner, group: group)

      sign_in owner
      expect {
        delete group_path(id: group.id)
      }.not_to change { company.groups.count }
      expect(flash[:alert]).to be_present
    end
  end
end
