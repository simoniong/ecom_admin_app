require "rails_helper"

RSpec.describe "ProductCustoms", type: :request do
  let(:user) { create(:user) }
  let(:store) { create(:shopify_store, user: user, company: user.companies.first) }
  let(:product) { create(:product, shopify_store: store) }
  let!(:variant) { create(:product_variant, product: product, sku: "ABC-1", title: "Default") }

  before { sign_in user }

  it "returns 200 and renders the variant" do
    get product_customs_path, params: { store_id: store.id }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("ABC-1")
  end

  it "filters by search" do
    create(:product_variant, product: product, sku: "OTHER-99")
    get product_customs_path, params: { store_id: store.id, search: "ABC" }
    expect(response.body).to include("ABC-1")
    expect(response.body).not_to include("OTHER-99")
  end

  it "redirects when no store is connected" do
    other_user = create(:user)
    sign_out user
    sign_in other_user
    get product_customs_path
    expect(response).to redirect_to(shopify_stores_path)
  end

  describe "the incomplete filter" do
    let!(:complete_variant) do
      create(:product_variant, product: product, sku: "COMPLETE-1",
             customs_name_zh: "積木", customs_name_en: "Blocks",
             declared_value_usd: 5, weight_grams: 100)
    end

    it "shows every variant when the filter is off" do
      get product_customs_path, params: { store_id: store.id }
      expect(response.body).to include("ABC-1")
      expect(response.body).to include("COMPLETE-1")
    end

    it "narrows to incomplete variants only when incomplete=1" do
      get product_customs_path, params: { store_id: store.id, incomplete: "1" }
      expect(response.body).to include("ABC-1")
      expect(response.body).not_to include("COMPLETE-1")
    end
  end

  describe "products permission gate" do
    let(:owner) { create(:user) }
    let(:company) { owner.companies.first }
    let!(:gate_store) { create(:shopify_store, company: company, user: owner) }

    it "allows a member granted the products permission" do
      m = create(:user)
      create(:membership, user: m, company: company, role: :member, permissions: [ "products" ])
      sign_in m
      patch switch_company_path(id: company.id)
      get product_customs_path
      expect(response).to have_http_status(:ok)
    end

    it "denies a member without the products permission (redirect)" do
      m = create(:user)
      create(:membership, user: m, company: company, role: :member, permissions: [ "shopify_stores" ])
      sign_in m
      patch switch_company_path(id: company.id)
      get product_customs_path
      expect(response).to redirect_to(authenticated_root_path)
    end
  end
end
