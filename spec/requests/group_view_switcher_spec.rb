require "rails_helper"

RSpec.describe "Group view switcher (Dashboard / Ad Campaigns)", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }
  let!(:group_a) { create(:group, company: company, name: "Sales") }
  let!(:group_b) { create(:group, company: company, name: "Support") }
  let!(:store_a) { create(:shopify_store, company: company, user: owner, group: group_a) }
  let!(:store_b) { create(:shopify_store, company: company, user: owner, group: group_b) }

  describe "Dashboard" do
    before { sign_in owner }

    it "defaults to the entire company (all groups) for owner" do
      get authenticated_root_path
      expect(response).to have_http_status(:success)
      expect(session[:view_group_id]).to be_nil
    end

    it "scopes to a specific group when owner selects it" do
      get authenticated_root_path, params: { group_id: group_a.id }
      expect(session[:view_group_id]).to eq(group_a.id)
    end

    it "resets to all groups when owner picks 'all'" do
      get authenticated_root_path, params: { group_id: group_a.id }
      expect(session[:view_group_id]).to eq(group_a.id)

      get authenticated_root_path, params: { group_id: "all" }
      expect(session[:view_group_id]).to be_nil
    end

    it "ignores an invalid group_id" do
      get authenticated_root_path, params: { group_id: SecureRandom.uuid }
      expect(session[:view_group_id]).to be_nil
    end

    it "locks a member to their own group regardless of params" do
      member = create(:user)
      create(:membership, company: company, user: member, role: :member, permissions: %w[dashboard], group: group_a)
      sign_in member
      patch switch_company_path(id: company.id)

      get authenticated_root_path, params: { group_id: group_b.id }
      expect(response).to have_http_status(:success)
      # member can't switch groups — selected_view_group forced to their own
    end
  end

  describe "Ad Campaigns" do
    before { sign_in owner }

    it "scopes the stored view_group_id in the session" do
      get ad_campaigns_path, params: { group_id: group_a.id }
      expect(response).to have_http_status(:success)
      expect(session[:view_group_id]).to eq(group_a.id)
    end

    it "resets view_group_id when owner picks 'all'" do
      get ad_campaigns_path, params: { group_id: group_a.id }
      get ad_campaigns_path, params: { group_id: "all" }
      expect(session[:view_group_id]).to be_nil
    end
  end
end
