require "rails_helper"

RSpec.describe "Companies creation", type: :request do
  let(:creator) do
    create(:user, email: User::COMPANY_CREATOR_EMAILS.first)
  end
  let(:regular_user) { create(:user) }

  describe "GET /company/new" do
    it "renders for an authorized creator" do
      sign_in creator
      get new_company_path
      expect(response).to have_http_status(:success)
    end

    it "redirects a non-creator user with a permission alert" do
      sign_in regular_user
      get new_company_path
      expect(response).to redirect_to(authenticated_root_path)
      expect(flash[:alert]).to be_present
    end

    it "redirects an unauthenticated user" do
      get new_company_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "POST /company" do
    it "creates a company and an owner membership for the authorized creator" do
      sign_in creator

      expect {
        post company_path, params: { company: { name: "Blue Ocean", locale: "en" } }
      }.to change(Company, :count).by(1).and change(Membership, :count).by(1)

      new_company = Company.find_by(name: "Blue Ocean")
      expect(new_company).to be_present
      expect(creator.membership_for(new_company)).to be_owner
      expect(response).to redirect_to(authenticated_root_path)
    end

    it "switches the session to the newly created company" do
      sign_in creator
      post company_path, params: { company: { name: "Switch Me", locale: "en" } }

      new_company = Company.find_by(name: "Switch Me")
      expect(session[:company_id]).to eq(new_company.id)
    end

    it "rejects a blank name without creating anything" do
      sign_in creator
      expect {
        post company_path, params: { company: { name: "", locale: "en" } }
      }.not_to change(Company, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "blocks a regular user from creating a company" do
      sign_in regular_user
      expect {
        post company_path, params: { company: { name: "Sneaky", locale: "en" } }
      }.not_to change(Company, :count)
      expect(response).to redirect_to(authenticated_root_path)
    end

    it "handles email case-insensitively in the allow-list" do
      uppercase_creator = create(:user, email: User::COMPANY_CREATOR_EMAILS.first.upcase)
      sign_in uppercase_creator

      expect {
        post company_path, params: { company: { name: "Case Test", locale: "en" } }
      }.to change(Company, :count).by(1)
    end
  end
end
