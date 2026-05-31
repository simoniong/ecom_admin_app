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
end
