require "rails_helper"

RSpec.describe "AdAccounts", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  describe "GET /ad_accounts" do
    it "returns success for authenticated user" do
      sign_in user
      get ad_accounts_path
      expect(response).to have_http_status(:success)
    end

    it "redirects unauthenticated user" do
      get ad_accounts_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "shows connect meta button" do
      sign_in user
      get ad_accounts_path
      expect(response.body).to include("Connect Meta Ads")
    end

    it "lists bound ad accounts" do
      create(:ad_account, user: user, account_name: "My Ad Account")
      sign_in user
      get ad_accounts_path
      expect(response.body).to include("My Ad Account")
    end

    it "shows empty state when no accounts" do
      sign_in user
      get ad_accounts_path
      expect(response.body).to include("No ad accounts connected yet")
    end

    it "does not show other users accounts" do
      create(:ad_account, user: other_user, account_name: "Other Account")
      sign_in user
      get ad_accounts_path
      expect(response.body).not_to include("Other Account")
    end
  end

  describe "GET /ad_accounts/:id" do
    it "shows ad account details" do
      account = create(:ad_account, user: user, account_name: "Show Account", account_id: "act_12345")
      sign_in user
      get ad_account_path(id: account.id)
      expect(response).to have_http_status(:success)
      expect(response.body).to include("Show Account")
      expect(response.body).to include("act_12345")
    end

    it "returns 404 for another user's account" do
      account = create(:ad_account, user: other_user)
      sign_in user
      get ad_account_path(id: account.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /ad_accounts/:id" do
    it "disconnects ad account" do
      account = create(:ad_account, user: user)
      sign_in user
      expect {
        delete ad_account_path(id: account.id)
      }.to change(AdAccount, :count).by(-1)
      expect(response).to redirect_to(ad_accounts_path)
    end

    it "deletes associated metrics" do
      account = create(:ad_account, user: user)
      create(:ad_daily_metric, ad_account: account)
      sign_in user
      expect {
        delete ad_account_path(id: account.id)
      }.to change(AdDailyMetric, :count).by(-1)
    end

    it "returns 404 for another user's account" do
      account = create(:ad_account, user: other_user)
      sign_in user
      delete ad_account_path(id: account.id)
      expect(response).to have_http_status(:not_found)
    end
  end
end
