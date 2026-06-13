require "rails_helper"

RSpec.describe "Shipments carrier change", type: :system do
  let!(:user) { create(:user) }

  before do
    membership = user.membership_for(user.companies.first)
    membership.update!(permissions: membership.permissions + [ "shipments" ])
    company = user.companies.first
    company.update!(tracking_enabled: true, tracking_api_key: "A" * 32,
                    tracking_mode: "new_only", tracking_starts_at: Time.current)
    store = create(:shopify_store, company: company)
    order = create(:order, shopify_store: store)
    create(:fulfillment, order: order, tracking_number: "SYS_CARRIER_1", tracking_status: "InTransit")

    allow(CarrierCatalog).to receive(:default)
      .and_return(CarrierCatalog.new(path: Rails.root.join("spec/fixtures/files/17track_carriers.json")))
  end

  it "changes carrier for selected shipments via the hover bar" do
    sign_in_as(user)
    visit shipments_path

    find("[data-shipment-bulk-target='selectAll']").check
    click_button I18n.t("shipments.carrier.button")

    # Scope to the modal: the hover-bar trigger and the modal submit share the
    # same "Change carrier" label, so an unscoped click would be ambiguous.
    within("[data-carrier-picker-target='modal']") do
      # Wait for the lazily-fetched carrier list to render before interacting,
      # otherwise an early keystroke hits the picker's "carriers not loaded" guard.
      expect(page).to have_selector("[data-carrier-picker-target='results'] button")
      fill_in placeholder: I18n.t("shipments.carrier.search_placeholder"), with: "China Post"
      find("[data-carrier-picker-target='results'] button", text: "China Post").click
      click_button I18n.t("shipments.carrier.confirm")
    end

    expect(page).to have_text(I18n.t("shipments.carrier.queued", count: 1))
  end
end
