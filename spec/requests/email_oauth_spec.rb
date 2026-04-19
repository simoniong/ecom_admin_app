require "rails_helper"

RSpec.describe "EmailOauth", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }

  describe "POST /email_oauth/start" do
    it "redirects to Google OAuth without group_id when company has no groups" do
      sign_in owner
      post email_oauth_start_path
      expect(response).to redirect_to("/auth/google_oauth2")
      expect(session[:pending_binding_group_id]).to be_nil
    end

    it "stores group_id in session when owner provides one" do
      group = create(:group, company: company)
      sign_in owner
      post email_oauth_start_path, params: { group_id: group.id }
      expect(response).to redirect_to("/auth/google_oauth2")
      expect(session[:pending_binding_group_id]).to eq(group.id)
    end

    it "rejects an owner without a group when company has groups" do
      _ = create(:group, company: company)
      sign_in owner
      post email_oauth_start_path
      expect(response).to redirect_to(email_accounts_path)
      expect(flash[:alert]).to be_present
    end

    it "auto-stores member's own group and ignores params" do
      group = create(:group, company: company)
      other_group = create(:group, company: company, name: "Other")
      member = create(:user)
      create(:membership, company: company, user: member, role: :member, permissions: %w[email_accounts], group: group)
      sign_in member
      patch switch_company_path(id: company.id)

      post email_oauth_start_path, params: { group_id: other_group.id }

      expect(response).to redirect_to("/auth/google_oauth2")
      expect(session[:pending_binding_group_id]).to eq(group.id)
    end

    it "blocks a member without email_accounts permission" do
      group = create(:group, company: company)
      member = create(:user)
      create(:membership, company: company, user: member, role: :member, permissions: %w[dashboard], group: group)
      sign_in member
      patch switch_company_path(id: company.id)

      post email_oauth_start_path
      expect(response).to redirect_to(authenticated_root_path)
    end
  end
end
