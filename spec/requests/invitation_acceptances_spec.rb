require "rails_helper"

RSpec.describe "InvitationAcceptances", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }

  describe "GET /invitations/:token (show)" do
    it "shows accept button when user is signed in" do
      invitation = create(:invitation, company: company, invited_by: owner)
      new_user = create(:user)
      sign_in new_user
      get accept_invitation_path(token: invitation.token)
      expect(response).to have_http_status(:success)
      expect(response.body).to include(t("invitations.accept_button"))
    end

    it "shows login form when user has an account but is not signed in" do
      create(:user, email: "existing@example.com")
      invitation = create(:invitation, company: company, invited_by: owner, email: "existing@example.com")
      get accept_invitation_path(token: invitation.token)
      expect(response).to have_http_status(:success)
      expect(response.body).to include("login")
      expect(response.body).to include("existing@example.com")
    end

    it "shows registration form when email has no account" do
      invitation = create(:invitation, company: company, invited_by: owner, email: "brand_new@example.com")
      get accept_invitation_path(token: invitation.token)
      expect(response).to have_http_status(:success)
      expect(response.body).to include("register")
      expect(response.body).to include("brand_new@example.com")
    end

    it "redirects if already a member" do
      invitation = create(:invitation, company: company, invited_by: owner)
      sign_in owner
      get accept_invitation_path(token: invitation.token)
      expect(response).to redirect_to(authenticated_root_path)
    end
  end

  describe "POST /invitations/:token/accept" do
    context "when signed in" do
      it "accepts the invitation and creates membership" do
        invitation = create(:invitation, company: company, invited_by: owner, role: :member, permissions: %w[orders])
        new_user = create(:user)
        sign_in new_user

        expect {
          post accept_invitation_confirm_path(token: invitation.token)
        }.to change(Membership, :count).by(1)

        expect(response).to redirect_to(authenticated_root_path)
        membership = new_user.membership_for(company)
        expect(membership).to be_present
        expect(membership.role).to eq("member")
      end

      it "rejects if already a member" do
        invitation = create(:invitation, company: company, invited_by: owner)
        sign_in owner
        post accept_invitation_confirm_path(token: invitation.token)
        expect(response).to redirect_to(authenticated_root_path)
        expect(flash[:alert]).to include("already")
      end
    end

    context "when logging in with existing account" do
      it "signs in and accepts with correct password" do
        existing_user = create(:user, email: "existing@example.com", password: "password123")
        invitation = create(:invitation, company: company, invited_by: owner, email: "existing@example.com", role: :member)

        expect {
          post accept_invitation_confirm_path(token: invitation.token),
               params: { state: "login", password: "password123" }
        }.to change(Membership, :count).by(1)

        expect(response).to redirect_to(authenticated_root_path)
      end

      it "re-renders with error on wrong password" do
        create(:user, email: "existing@example.com", password: "password123")
        invitation = create(:invitation, company: company, invited_by: owner, email: "existing@example.com")

        post accept_invitation_confirm_path(token: invitation.token),
             params: { state: "login", password: "wrong" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include(t("invitations.invalid_credentials"))
      end
    end

    context "when registering a new account" do
      it "creates user, signs in, and accepts" do
        invitation = create(:invitation, company: company, invited_by: owner, email: "newbie@example.com", role: :member)

        expect {
          post accept_invitation_confirm_path(token: invitation.token),
               params: { state: "register", first_name: "Alice", last_name: "Wang",
                         password: "password123", password_confirmation: "password123" }
        }.to change(User, :count).by(1).and change(Membership, :count).by(1)

        expect(response).to redirect_to(authenticated_root_path)
        user = User.find_by(email: "newbie@example.com")
        expect(user.first_name).to eq("Alice")
        expect(user.last_name).to eq("Wang")
      end

      it "re-renders with errors on invalid registration" do
        invitation = create(:invitation, company: company, invited_by: owner, email: "newbie@example.com")

        post accept_invitation_confirm_path(token: invitation.token),
             params: { state: "register", first_name: "", password: "short" }

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end

  private

  def t(key, **options)
    I18n.t(key, **options)
  end
end
