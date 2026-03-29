require "rails_helper"

RSpec.describe "ShopifyStores", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }

  describe "GET /shopify_stores" do
    it "returns success for authenticated user" do
      sign_in user
      get shopify_stores_path
      expect(response).to have_http_status(:success)
    end

    it "redirects unauthenticated user" do
      get shopify_stores_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "lists user's stores" do
      create(:shopify_store, user: user, shop_domain: "my-store.myshopify.com")
      sign_in user
      get shopify_stores_path
      expect(response.body).to include("my-store.myshopify.com")
    end

    it "does not show other users stores" do
      create(:shopify_store, user: other_user, shop_domain: "other-store.myshopify.com")
      sign_in user
      get shopify_stores_path
      expect(response.body).not_to include("other-store.myshopify.com")
    end

    it "shows empty state when no stores" do
      sign_in user
      get shopify_stores_path
      expect(response.body).to include(I18n.t("shopify_stores.empty"))
    end
  end

  describe "GET /shopify_stores/:id" do
    it "shows store details" do
      store = create(:shopify_store, user: user, shop_domain: "detail-store.myshopify.com")
      sign_in user
      get shopify_store_path(id: store.id)
      expect(response).to have_http_status(:success)
      expect(response.body).to include("detail-store.myshopify.com")
    end

    it "returns 404 for another user's store" do
      store = create(:shopify_store, user: other_user)
      sign_in user
      get shopify_store_path(id: store.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /shopify_stores/:id" do
    it "links email accounts to store" do
      store = create(:shopify_store, user: user)
      account = create(:email_account, user: user)
      sign_in user

      patch shopify_store_path(id: store.id), params: { email_account_ids: [ account.id ] }
      expect(response).to redirect_to(shopify_store_path(store))
      expect(account.reload.shopify_store_id).to eq(store.id)
    end

    it "unlinks previously linked accounts" do
      store = create(:shopify_store, user: user)
      account = create(:email_account, user: user, shopify_store: store)
      sign_in user

      patch shopify_store_path(id: store.id), params: { email_account_ids: [ "" ] }
      expect(account.reload.shopify_store_id).to be_nil
    end

    it "returns 404 for another user's store" do
      store = create(:shopify_store, user: other_user)
      sign_in user
      patch shopify_store_path(id: store.id), params: { email_account_ids: [] }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /shopify_stores/:id" do
    it "disconnects store" do
      store = create(:shopify_store, user: user)
      sign_in user
      expect {
        delete shopify_store_path(id: store.id)
      }.to change(ShopifyStore, :count).by(-1)
      expect(response).to redirect_to(shopify_stores_path)
    end

    it "nullifies linked email accounts" do
      store = create(:shopify_store, user: user)
      account = create(:email_account, user: user, shopify_store: store)
      sign_in user

      delete shopify_store_path(id: store.id)
      expect(account.reload.shopify_store_id).to be_nil
    end

    it "returns 404 for another user's store" do
      store = create(:shopify_store, user: other_user)
      sign_in user
      delete shopify_store_path(id: store.id)
      expect(response).to have_http_status(:not_found)
    end
  end
end
