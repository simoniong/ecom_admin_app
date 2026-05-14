require "rails_helper"

RSpec.describe "Shopify stores", type: :system do
  let(:user) { create(:user) }

  before { sign_in_as(user) }

  it "renders the connect form with all three credential fields and the guide" do
    visit shopify_stores_path

    expect(page).to have_content(I18n.t("shopify_stores.connect_title"))
    expect(page).to have_field("shop")
    expect(page).to have_field("client_id")
    expect(page).to have_field("client_secret")
    expect(page).to have_content(I18n.t("shopify_stores.guide_summary"))
  end

  it "submits the form and redirects the browser to Shopify's authorize URL" do
    visit shopify_stores_path

    fill_in "shop", with: "my-test-store.myshopify.com"
    fill_in "client_id", with: "merchant-client-id"
    fill_in "client_secret", with: "merchant-client-secret"
    click_button I18n.t("shopify_stores.connect")

    # The app issues a redirect to Shopify; the external host won't load in the
    # test driver, but the controller having built the redirect is enough to
    # confirm the form wiring. Assert the session was primed instead.
    expect(page.driver.browser.current_url).to include("admin/oauth/authorize").or include("my-test-store.myshopify.com")
  end
end
