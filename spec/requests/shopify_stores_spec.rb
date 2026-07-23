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

    it "renders the connect form with credential fields and the setup guide" do
      sign_in user
      get shopify_stores_path
      expect(response.body).to include(I18n.t("shopify_stores.connect_title"))
      expect(response.body).to include(I18n.t("shopify_stores.guide_summary"))
      expect(response.body).to match(/name="client_id"/)
      expect(response.body).to match(/name="client_secret"/)
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

    it "shows the client_id but not the client_secret" do
      store = create(:shopify_store, user: user,
                     client_id: "visible-client-id", client_secret: "shpss_secret_value")
      sign_in user
      get shopify_store_path(id: store.id)
      expect(response.body).to include(I18n.t("shopify_stores.show.client_id"))
      expect(response.body).to include("visible-client-id")
      expect(response.body).not_to include("shpss_secret_value")
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

  describe "PATCH /shopify_stores/:id with cost_fx_rate" do
    let(:store) { create(:shopify_store, user: user, company: user.companies.first) }

    before { sign_in user }

    it "updates cost_fx_rate when user is owner" do
      patch shopify_store_path(id: store.id), params: { shopify_store: { cost_fx_rate: "7.2000" } }
      expect(store.reload.cost_fx_rate).to eq(7.2)
      expect(response).to redirect_to(shopify_store_path(store))
    end

    it "rejects zero" do
      patch shopify_store_path(id: store.id), params: { shopify_store: { cost_fx_rate: "0" } }
      expect(store.reload.cost_fx_rate).to be_nil
    end

    it "accepts clearing the rate" do
      store.update!(cost_fx_rate: 7.2)
      patch shopify_store_path(id: store.id), params: { shopify_store: { cost_fx_rate: "" } }
      expect(store.reload.cost_fx_rate).to be_nil
    end

    it "blocks non-owner members from changing cost_fx_rate" do
      # Owner-only financial setting; member with shopify_stores page access alone
      # must NOT be able to alter the conversion rate used for profit math.
      member = create(:user)
      company = user.companies.first
      create(:membership, user: member, company: company, role: :member, permissions: [ "shopify_stores" ])
      sign_out user
      sign_in member

      patch shopify_store_path(id: store.id), params: { shopify_store: { cost_fx_rate: "9.99" } }

      expect(store.reload.cost_fx_rate).to be_nil
      expect(flash[:alert]).to be_present
    end
  end

  describe "POST /shopify_stores/:id/sync_products" do
    let(:store) { create(:shopify_store, user: user, company: user.companies.first) }

    before { sign_in user }

    it "enqueues SyncShopifyProductsJob" do
      expect {
        post sync_products_shopify_store_path(id: store.id)
      }.to have_enqueued_job(SyncShopifyProductsJob).with(store.id)
    end

    it "redirects with notice" do
      post sync_products_shopify_store_path(id: store.id)
      expect(response).to redirect_to(shopify_store_path(store))
    end
  end

  describe "PATCH /shopify_stores/:id default_service_type" do
    let(:owner) { create(:user) }
    let(:company) { owner.companies.first }
    let(:store) { create(:shopify_store, user: owner, company: company) }
    let(:member_user) { create(:user) }
    let!(:member_membership) do
      create(:membership, company: company, user: member_user, role: :member, permissions: %w[shopify_stores])
    end

    it "updates default_service_type for an owner" do
      sign_in owner
      patch shopify_store_path(id: store.id), params: { shopify_store: { default_service_type: "with_battery" } }
      expect(store.reload.default_service_type).to eq("with_battery")
      expect(response).to redirect_to(shopify_store_path(id: store.id))
    end

    it "blocks a non-owner" do
      sign_in member_user
      patch switch_company_path(id: company.id)
      patch shopify_store_path(id: store.id), params: { shopify_store: { default_service_type: "hacked" } }
      expect(store.reload.default_service_type).to be_nil
    end
  end

  describe "PATCH /shopify_stores/:id trustpilot_bcc_email" do
    let(:user)  { create(:user) }
    let(:store) { create(:shopify_store, user: user, company: user.companies.first) }

    it "lets an owner set the Trustpilot BCC address" do
      sign_in user
      patch shopify_store_path(id: store.id), params: { shopify_store: { trustpilot_bcc_email: "shop.com+abc@invite.trustpilot.com" } }
      expect(store.reload.trustpilot_bcc_email).to eq("shop.com+abc@invite.trustpilot.com")
    end

    it "rejects a malformed address" do
      sign_in user
      patch shopify_store_path(id: store.id), params: { shopify_store: { trustpilot_bcc_email: "nope" } }
      expect(store.reload.trustpilot_bcc_email).to be_nil
      follow_redirect!
      expect(response.body).to include(CGI.escapeHTML("Trustpilot"))
    end

    it "forbids a non-owner member from changing it" do
      member = create(:user)
      create(:membership, user: member, company: user.companies.first, role: :member, permissions: [ "shopify_stores" ])
      sign_in member
      patch switch_company_path(id: user.companies.first.id)
      patch shopify_store_path(id: store.id), params: { shopify_store: { trustpilot_bcc_email: "shop.com+abc@invite.trustpilot.com" } }
      expect(store.reload.trustpilot_bcc_email).to be_nil
    end
  end

  describe "PATCH /shopify_stores/:id packing settings" do
    let(:user)  { create(:user) }
    let(:store) { create(:shopify_store, user: user, company: user.companies.first) }

    it "lets an owner enable packing with a prefix and start number" do
      sign_in user
      patch shopify_store_path(id: store.id), params: {
        shopify_store: { packing_enabled: "1", package_prefix: "PK", package_number_start: "1000" }
      }
      store.reload
      expect(store.packing_enabled).to be true
      expect(store.package_prefix).to eq("PK")
      expect(store.package_number_start).to eq(1000)
      expect(response).to redirect_to(shopify_store_path(store))
    end

    it "rejects enabling packing without a prefix" do
      sign_in user
      patch shopify_store_path(id: store.id), params: {
        shopify_store: { packing_enabled: "1", package_prefix: "", package_number_start: "1000" }
      }
      store.reload
      expect(store.packing_enabled).to be false
      follow_redirect!
      expect(response.body).to include(CGI.escapeHTML("Package prefix"))
    end

    it "rejects changing the prefix once a package exists (locked)" do
      store.update!(packing_enabled: true, package_prefix: "PK", package_number_start: 1)
      create(:package, shopify_store: store)
      sign_in user

      patch shopify_store_path(id: store.id), params: {
        shopify_store: { packing_enabled: "1", package_prefix: "NEW", package_number_start: "1" }
      }
      expect(store.reload.package_prefix).to eq("PK")
      follow_redirect!
      expect(response.body).to include(CGI.escapeHTML("cannot be changed after the first package is created"))
    end

    it "forbids a non-owner member from changing packing settings" do
      member = create(:user)
      create(:membership, user: member, company: user.companies.first, role: :member, permissions: [ "shopify_stores" ])
      sign_in member
      patch switch_company_path(id: user.companies.first.id)
      patch shopify_store_path(id: store.id), params: {
        shopify_store: { packing_enabled: "1", package_prefix: "PK", package_number_start: "1" }
      }
      expect(store.reload.packing_enabled).to be false
    end
  end

  describe "PATCH /shopify_stores/:id shipping_sync_enabled" do
    let(:user)  { create(:user) }
    let(:store) { create(:shopify_store, user: user, company: user.companies.first) }

    it "updates shipping_sync_enabled (owner only)" do
      sign_in user
      patch shopify_store_path(id: store.id), params: { shopify_store: { shipping_sync_enabled: true } }
      expect(store.reload.shipping_sync_enabled).to be(true)
    end

    it "forbids a non-owner member from changing it" do
      member = create(:user)
      create(:membership, user: member, company: user.companies.first, role: :member, permissions: [ "shopify_stores" ])
      sign_in member
      patch switch_company_path(id: user.companies.first.id)
      patch shopify_store_path(id: store.id), params: { shopify_store: { shipping_sync_enabled: true } }
      expect(store.reload.shipping_sync_enabled).to be(false)
    end
  end
end
