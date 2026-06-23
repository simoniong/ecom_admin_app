require "rails_helper"

RSpec.describe "Store switcher", type: :system do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }
  let!(:store_a) { create(:shopify_store, company: company, user: owner, shop_domain: "alpha-store.myshopify.com") }
  let!(:store_b) { create(:shopify_store, company: company, user: owner, shop_domain: "bravo-store.myshopify.com") }

  before { sign_in_as(owner) }

  it "shows an All Stores option on the dashboard" do
    visit authenticated_root_path
    within("[data-testid='store-switcher']") do
      expect(page).to have_select(with_options: [ "All Stores", "alpha-store.myshopify.com", "bravo-store.myshopify.com" ])
    end
  end

  it "does not show an All Stores option on orders" do
    visit orders_path
    within("[data-testid='store-switcher']") do
      expect(page).not_to have_select(with_options: [ "All Stores" ])
      expect(page).to have_select(with_options: [ "alpha-store.myshopify.com", "bravo-store.myshopify.com" ])
    end
  end

  it "does not render the switcher on settings pages" do
    visit shopify_stores_path
    expect(page).not_to have_css("[data-testid='store-switcher']")
  end

  it "navigates with store_id in the URL when a store is selected" do
    visit orders_path
    within("[data-testid='store-switcher']") do
      select "bravo-store.myshopify.com"
    end
    expect(page).to have_current_path(/store_id=#{store_b.id}/, url: false)
  end
end
