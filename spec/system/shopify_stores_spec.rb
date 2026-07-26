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

  it "accepts the connect form submission without a credential error" do
    visit shopify_stores_path

    fill_in "shop", with: "my-test-store.myshopify.com"
    fill_in "client_id", with: "merchant-client-id"
    fill_in "client_secret", with: "merchant-client-secret"
    click_button I18n.t("shopify_stores.connect")

    # The controller redirects to Shopify's external host, which the browser
    # driver cannot load; the redirect-building itself is fully covered by
    # spec/requests/shopify_oauth_spec.rb. Here we only confirm the form wired
    # its fields correctly — i.e. it did NOT bounce back with the
    # "credentials required" validation error.
    expect(page).not_to have_content(I18n.t("shopify_stores.credentials_required"))
  end

  it "shows packing prefix and start number as read-only once the store has packages" do
    store = create(:shopify_store, user: user, company: user.companies.first,
                   packing_enabled: true, package_prefix: "PK", package_number_start: 1)
    create(:package, shopify_store: store)

    visit shopify_store_path(id: store.id)

    expect(page).to have_content(I18n.t("shopify_stores.packing_locked_hint"))
    expect(page).to have_field("shopify_store_package_prefix", disabled: true)
    expect(page).to have_field("shopify_store_package_number_start", disabled: true)
  end
end
