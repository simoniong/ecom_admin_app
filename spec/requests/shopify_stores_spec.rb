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

    it "renders the first-install instruction card" do
      sign_in user
      get shopify_stores_path
      expect(response.body).to include(I18n.t("shopify_stores.first_install_title"))
      expect(response.body).to include(I18n.t("shopify_stores.first_install_description"))
    end

    it "renders the reauthorize form heading" do
      sign_in user
      get shopify_stores_path
      expect(response.body).to include(I18n.t("shopify_stores.reauth_title"))
      expect(response.body).to include(I18n.t("shopify_stores.reauth_button"))
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

    it "links ad accounts to store" do
      store = create(:shopify_store, user: user)
      ad_account = create(:ad_account, user: user)
      sign_in user

      patch shopify_store_path(id: store.id), params: { ad_account_ids: [ ad_account.id ] }
      expect(response).to redirect_to(shopify_store_path(store))
      expect(ad_account.reload.shopify_store_id).to eq(store.id)
    end

    it "unlinks previously linked ad accounts" do
      store = create(:shopify_store, user: user)
      ad_account = create(:ad_account, user: user, shopify_store: store)
      sign_in user

      patch shopify_store_path(id: store.id), params: { ad_account_ids: [ "" ] }
      expect(ad_account.reload.shopify_store_id).to be_nil
    end

    it "links both email and ad accounts in a single update" do
      store = create(:shopify_store, user: user)
      email_account = create(:email_account, user: user)
      ad_account = create(:ad_account, user: user)
      sign_in user

      patch shopify_store_path(id: store.id), params: {
        email_account_ids: [ email_account.id ],
        ad_account_ids: [ ad_account.id ]
      }
      expect(email_account.reload.shopify_store_id).to eq(store.id)
      expect(ad_account.reload.shopify_store_id).to eq(store.id)
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

    it "nullifies linked ad accounts" do
      store = create(:shopify_store, user: user)
      ad_account = create(:ad_account, user: user, shopify_store: store)
      sign_in user

      delete shopify_store_path(id: store.id)
      expect(ad_account.reload.shopify_store_id).to be_nil
    end

    it "deletes customers, orders, and fulfillments belonging to the store" do
      store = create(:shopify_store, user: user)
      customer = create(:customer, shopify_store: store)
      order = create(:order, customer: customer, shopify_store: store)
      fulfillment = create(:fulfillment, order: order)
      sign_in user

      delete shopify_store_path(id: store.id)

      expect(Customer.exists?(customer.id)).to be false
      expect(Order.exists?(order.id)).to be false
      expect(Fulfillment.exists?(fulfillment.id)).to be false
    end

    it "nullifies customer_id on tickets when deleting store with customer that has tickets" do
      store = create(:shopify_store, user: user)
      customer = create(:customer, shopify_store: store)
      email_account = create(:email_account, user: user)
      ticket = create(:ticket, email_account: email_account, customer: customer)
      sign_in user

      expect {
        delete shopify_store_path(id: store.id)
      }.to change(ShopifyStore, :count).by(-1)

      expect(response).to redirect_to(shopify_stores_path)
      expect(ticket.reload.customer_id).to be_nil
      expect(Ticket.exists?(ticket.id)).to be true
    end

    it "returns 404 for another user's store" do
      store = create(:shopify_store, user: other_user)
      sign_in user
      delete shopify_store_path(id: store.id)
      expect(response).to have_http_status(:not_found)
    end
  end
end
