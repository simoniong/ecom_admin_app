require "rails_helper"

RSpec.describe "EmailAccounts", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  describe "GET /email_accounts" do
    it "returns success for authenticated user" do
      sign_in user
      get email_accounts_path
      expect(response).to have_http_status(:success)
    end

    it "redirects unauthenticated user" do
      get email_accounts_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "shows bind new email button" do
      sign_in user
      get email_accounts_path
      expect(response.body).to include("Bind New Email")
    end

    it "lists bound email accounts" do
      create(:email_account, user: user, email: "listed@gmail.com")
      sign_in user
      get email_accounts_path
      expect(response.body).to include("listed@gmail.com")
    end

    it "shows empty state when no accounts" do
      sign_in user
      get email_accounts_path
      expect(response.body).to include("No email accounts linked yet.")
    end
  end

  describe "GET /email_accounts/:id" do
    it "shows email account details" do
      account = create(:email_account, user: user, email: "show@gmail.com", google_uid: "show-uid",
                       access_token: "show-token", refresh_token: "show-refresh", scopes: "email,profile")
      sign_in user
      get email_account_path(id: account.id)
      expect(response).to have_http_status(:success)
      expect(response.body).to include("show@gmail.com")
      expect(response.body).to include("show-uid")
      expect(response.body).to include("show-token")
      expect(response.body).to include("show-refresh")
    end

    it "returns 404 for another user's account" do
      account = create(:email_account, user: other_user)
      sign_in user
      get email_account_path(id: account.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /email_accounts/:id" do
    it "disconnects email account" do
      account = create(:email_account, user: user)
      sign_in user
      expect {
        delete email_account_path(id: account.id)
      }.to change(EmailAccount, :count).by(-1)
      expect(response).to redirect_to(email_accounts_path)
    end

    it "returns 404 for another user's account" do
      account = create(:email_account, user: other_user)
      sign_in user
      delete email_account_path(id: account.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "OAuth callback" do
    it "creates email account on successful callback" do
      sign_in user
      expect {
        get "/auth/google_oauth2/callback"
      }.to change(EmailAccount, :count).by(1)

      account = user.email_accounts.last
      expect(account.email).to eq("oauth-test@gmail.com")
      expect(account.google_uid).to eq("google-uid-999")
      expect(response).to redirect_to(email_accounts_path)
    end

    it "updates existing account on re-bind" do
      existing = create(:email_account, user: user, google_uid: "rebind-uid",
                        access_token: "old-token", refresh_token: "old-refresh")

      OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
        provider: "google_oauth2",
        uid: "rebind-uid",
        info: { email: existing.email, name: "Rebind User" },
        credentials: {
          token: "new-access-token",
          refresh_token: "new-refresh-token",
          expires_at: 2.hours.from_now.to_i
        }
      )

      sign_in user
      expect {
        get "/auth/google_oauth2/callback"
      }.not_to change(EmailAccount, :count)

      existing.reload
      expect(existing.access_token).to eq("new-access-token")
    end

    it "redirects with alert on failure" do
      sign_in user
      get "/auth/failure"
      expect(response).to redirect_to(email_accounts_path)
      follow_redirect!
      expect(response.body).to include("Google authentication failed")
    end
  end
end
