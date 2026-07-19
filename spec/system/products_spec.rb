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

  it "renders the packaging cost column with a default of 0.00" do
    variant.update!(packaging_cost: 0)
    visit products_path(store_id: store.id)
    expect(page).to have_text(/packaging cost/i)
    expect(page).to have_content("0.00")
  end

  describe "Products nav-group" do
    it "expands to reveal Product Costs and Customs Info when clicked" do
      visit authenticated_root_path

      within "nav" do
        expect(page).to have_no_css("#products-menu", visible: :visible)
        click_button I18n.t("nav.products")
        expect(page).to have_css("#products-menu", visible: :visible)
        expect(page).to have_link(I18n.t("nav.product_costs"))
        expect(page).to have_link(I18n.t("nav.product_customs"))
      end
    end
  end
end
