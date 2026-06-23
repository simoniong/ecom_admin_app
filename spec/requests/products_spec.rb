require "rails_helper"

RSpec.describe "Products", type: :request do
  let(:user) { create(:user) }
  let(:store) { create(:shopify_store, user: user, company: user.companies.first) }
  let(:product) { create(:product, shopify_store: store) }
  let!(:variant) { create(:product_variant, product: product, sku: "ABC-1", title: "Default") }

  before { sign_in user }

  it "returns 200 and renders the variant" do
    get products_path, params: { store_id: store.id }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("ABC-1")
  end

  it "filters by search" do
    create(:product_variant, product: product, sku: "OTHER-99")
    get products_path, params: { store_id: store.id, search: "ABC" }
    expect(response.body).to include("ABC-1")
    expect(response.body).not_to include("OTHER-99")
  end

  it "redirects when no store is connected" do
    other_user = create(:user)
    sign_out user
    sign_in other_user
    get products_path
    expect(response).to redirect_to(shopify_stores_path)
  end

  describe "session store confinement" do
    it "does not inherit a switcher-page session store; defaults to first store regardless of session" do
      company = user.companies.first
      store_b = create(:shopify_store, company: company, user: user)

      product_b = create(:product, shopify_store: store_b)
      create(:product_variant, product: product_b, sku: "STORE-B-SESSION-SKU")

      # Set the session to store_b via the dashboard (a switcher page)
      get authenticated_root_path, params: { store_id: store_b.id }
      expect(session[:store_id]).to eq(store_b.id)

      # GET products with NO store_id — non-switcher: session must be ignored.
      # Two stores → resolve_current_store returns nil → ProductsController uses first store.
      get products_path
      expect(response).to have_http_status(:ok)
      # First store (store) has variant "ABC-1"; second store's variant must not appear.
      expect(response.body).to include("ABC-1")
      expect(response.body).not_to include("STORE-B-SESSION-SKU")
    end
  end
end
