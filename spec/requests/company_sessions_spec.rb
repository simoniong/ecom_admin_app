require "rails_helper"

RSpec.describe "CompanySessions", type: :request do
  let(:user) { create(:user) }
  let(:company1) { user.companies.first }
  let(:company2) { create(:company) }

  before do
    create(:membership, company: company2, user: user, role: :member, permissions: %w[dashboard orders])
  end

  describe "PATCH /switch_company/:id" do
    it "switches to a company the user belongs to" do
      sign_in user
      patch switch_company_path(id: company2.id)
      expect(response).to redirect_to(authenticated_root_path)
      # Verify the switch took effect
      get authenticated_root_path
      expect(response).to have_http_status(:success)
    end

    it "rejects switching to a company the user doesn't belong to" do
      other_company = create(:company)
      sign_in user
      patch switch_company_path(id: other_company.id)
      expect(response).to have_http_status(:not_found)
    end
  end
end
