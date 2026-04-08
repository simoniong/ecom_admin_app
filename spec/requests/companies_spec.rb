require "rails_helper"

RSpec.describe "Companies", type: :request do
  let(:user) { create(:user) }
  let(:company) { user.companies.first }

  describe "GET /company/edit" do
    it "returns success for owner" do
      sign_in user
      get edit_company_path
      expect(response).to have_http_status(:success)
    end

    it "redirects member to root" do
      member = create(:user)
      create(:membership, company: company, user: member, role: :member, permissions: %w[dashboard])
      sign_in member
      # Switch to the company where user is member
      patch switch_company_path(id: company.id)
      get edit_company_path
      expect(response).to redirect_to(authenticated_root_path)
    end
  end

  describe "PATCH /company" do
    it "updates company name for owner" do
      sign_in user
      patch company_path, params: { company: { name: "New Name" } }
      expect(response).to redirect_to(edit_company_path)
      expect(company.reload.name).to eq("New Name")
    end

    it "rejects blank name" do
      sign_in user
      patch company_path, params: { company: { name: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "redirects member" do
      member = create(:user)
      create(:membership, company: company, user: member, role: :member, permissions: %w[dashboard])
      sign_in member
      patch switch_company_path(id: company.id)
      patch company_path, params: { company: { name: "Hack" } }
      expect(response).to redirect_to(authenticated_root_path)
      expect(company.reload.name).not_to eq("Hack")
    end
  end
end
