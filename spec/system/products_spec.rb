require "rails_helper"

RSpec.describe "Products UI", type: :system do
  let(:user) { create(:user) }
  let(:store) { create(:shopify_store, user: user, company: user.companies.first) }
  let(:product) { create(:product, shopify_store: store, title: "Paint Kit") }
  let!(:variant) { create(:product_variant, product: product, sku: "PK-BL", title: "Black/Large") }

  before { sign_in_as(user) }

  it "shows variants on the products page" do
    visit products_path(store_id: store.id)
    expect(page).to have_content("Paint Kit")
    expect(page).to have_content("PK-BL")
    expect(page).to have_content("Black/Large")
  end

  it "filters by search" do
    create(:product_variant, product: product, sku: "OTHER-99")
    visit products_path(store_id: store.id, search: "PK-BL")
    expect(page).to have_content("PK-BL")
    expect(page).not_to have_content("OTHER-99")
  end

  it "renders the per_page selector with the current value" do
    visit products_path(store_id: store.id, per_page: 25)
    expect(page).to have_select("per_page", selected: "25")
  end
end
