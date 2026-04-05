require "rails_helper"

RSpec.describe "OauthCallbacks", type: :request do
  let(:user) { create(:user) }

  describe "GET /auth/google_oauth2/callback" do
    it "creates a new email account from OAuth data" do
      sign_in user

      auth_hash = OmniAuth::AuthHash.new(
        uid: "google-123",
        info: { email: "user@gmail.com" },
        credentials: {
          token: "access-token",
          refresh_token: "refresh-token",
          expires_at: 1.hour.from_now.to_i,
          scope: "https://www.googleapis.com/auth/gmail.modify"
        }
      )

      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:google_oauth2] = auth_hash

      get "/auth/google_oauth2/callback", env: { "omniauth.auth" => auth_hash }

      expect(response).to redirect_to(email_accounts_path)
      account = user.email_accounts.find_by(google_uid: "google-123")
      expect(account).to be_present
      expect(account.email).to eq("user@gmail.com")
    end

    it "updates existing email account on re-auth" do
      sign_in user
      existing = create(:email_account, user: user, google_uid: "google-existing", email: "old@gmail.com")

      auth_hash = OmniAuth::AuthHash.new(
        uid: "google-existing",
        info: { email: "updated@gmail.com" },
        credentials: { token: "new-token", refresh_token: "new-refresh", expires_at: 1.hour.from_now.to_i }
      )

      OmniAuth.config.test_mode = true
      OmniAuth.config.mock_auth[:google_oauth2] = auth_hash

      get "/auth/google_oauth2/callback", env: { "omniauth.auth" => auth_hash }

      expect(response).to redirect_to(email_accounts_path)
      existing.reload
      expect(existing.email).to eq("updated@gmail.com")
      expect(existing.access_token).to eq("new-token")
    end
  end

  describe "GET /auth/failure" do
    it "redirects to email accounts with alert" do
      sign_in user

      get "/auth/failure"

      expect(response).to redirect_to(email_accounts_path)
      expect(flash[:alert]).to be_present
    end
  end
end
