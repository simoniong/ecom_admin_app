require "rails_helper"

RSpec.describe "Store switcher resolution & persistence", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }
  let!(:store_a) { create(:shopify_store, company: company, user: owner) }
  let!(:store_b) { create(:shopify_store, company: company, user: owner) }

  before { sign_in owner }

  describe "Dashboard (All allowed)" do
    it "renders without forcing a store when nothing is selected" do
      get authenticated_root_path
      expect(response).to have_http_status(:success)
      expect(session[:store_id]).to be_nil
    end

    it "persists a selected store id in the session" do
      get authenticated_root_path, params: { store_id: store_a.id }
      expect(session[:store_id]).to eq(store_a.id)
    end

    it "remembers the store across a later page load with no param" do
      get authenticated_root_path, params: { store_id: store_a.id }
      get authenticated_root_path
      expect(session[:store_id]).to eq(store_a.id)
    end

    it "persists the literal 'all' selection" do
      get authenticated_root_path, params: { store_id: store_a.id }
      get authenticated_root_path, params: { store_id: "all" }
      expect(session[:store_id]).to eq("all")
    end
  end

  describe "Orders (All NOT allowed)" do
    it "succeeds and does not overwrite an existing 'all' selection" do
      get authenticated_root_path, params: { store_id: "all" }
      get orders_path
      expect(response).to have_http_status(:success)
      expect(session[:store_id]).to eq("all")
    end

    it "persists a concrete store chosen on Orders" do
      get orders_path, params: { store_id: store_b.id }
      expect(session[:store_id]).to eq(store_b.id)
    end

    it "ignores an explicit store_id=all on Orders (does not persist 'all')" do
      get orders_path, params: { store_id: "all" }
      expect(response).to have_http_status(:success)
      expect(session[:store_id]).to be_nil
    end
  end

  describe "stale selections" do
    it "renders fine when the session holds a no-longer-visible store_id" do
      get authenticated_root_path, params: { store_id: "00000000-0000-4000-8000-000000000000" }
      expect(response).to have_http_status(:success)
    end
  end

  describe "Settings pages (no switcher)" do
    it "does not write store_id to the session" do
      get shopify_stores_path, params: { store_id: store_a.id }
      expect(session[:store_id]).to be_nil
    end
  end

  describe "switching company" do
    it "clears the remembered store" do
      get authenticated_root_path, params: { store_id: store_a.id }
      other = create(:company)
      create(:membership, company: other, user: owner, role: :owner)
      patch switch_company_path(id: other.id)
      expect(session[:store_id]).to be_nil
    end

    it "clears the remembered store when creating a new company" do
      # Sign in as a company creator (required by CompaniesController#create)
      creator = create(:user, email: User::COMPANY_CREATOR_EMAILS.first)
      creator_store = create(:shopify_store, company: creator.companies.first, user: creator)
      sign_in creator

      # Establish a remembered store via the dashboard (switcher page)
      get authenticated_root_path, params: { store_id: creator_store.id }
      expect(session[:store_id]).to eq(creator_store.id)

      # Creating a new company must clear the remembered store
      post company_path, params: { company: { name: "Brand New Co", locale: "en" } }
      expect(session[:store_id]).to be_nil
    end
  end

  describe "Products (non-switcher controller)" do
    it "ignores the session store and defaults to the first store when there are multiple stores" do
      product_a = create(:product, shopify_store: store_a)
      create(:product_variant, product: product_a, sku: "STORE-A-ONLY-SKU")
      product_b = create(:product, shopify_store: store_b)
      create(:product_variant, product: product_b, sku: "STORE-B-ONLY-SKU")

      # Set session to store_b via the dashboard switcher
      get authenticated_root_path, params: { store_id: store_b.id }
      expect(session[:store_id]).to eq(store_b.id)

      # GET products with NO store_id param — Products must NOT inherit the session store.
      # With two stores, resolve_current_store returns nil for non-switcher pages,
      # so ProductsController falls back to visible_shopify_stores.first (store_a).
      get products_path
      expect(response).to have_http_status(:ok)
      # The page renders store_a's product (first store), not the store_b stored in session.
      expect(response.body).to include("STORE-A-ONLY-SKU")
      expect(response.body).not_to include("STORE-B-ONLY-SKU")
    end
  end
end
