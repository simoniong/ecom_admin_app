require "rails_helper"

RSpec.describe "Shipping rate cards", type: :system do
  let(:owner) { create(:user) }

  before { sign_in_as(owner) }

  it "creates a version, adds a band, and inline-edits a cell" do
    visit shipping_rate_card_versions_path

    within("div.bg-white.border.border-gray-200.rounded-lg.shadow-sm.p-5.mb-6") do
      fill_in "shipping_rate_card_version[name]", with: "Q2 2026 US Battery"
      # Country and service are dropdowns; select by option value (locale-independent).
      find("select[name='shipping_rate_card_version[country_code]'] option[value='US']").select_option
      find("select[name='shipping_rate_card_version[service_type]'] option[value='with_battery']").select_option
      # date inputs need MM/DD/YYYY in Chrome; send keystrokes instead of .set
      find("input[name='shipping_rate_card_version[effective_from]']").send_keys("04012026")
      click_button I18n.t("shipping_rate_cards.create_version")
    end

    expect(page).to have_content("Q2 2026 US Battery")

    version = ShippingRateCardVersion.last

    within("##{ActionView::RecordIdentifier.dom_id(version)}") do
      fill_in "shipping_rate_card_rate[weight_min_kg]", with: "0.05"
      fill_in "shipping_rate_card_rate[weight_max_kg]", with: "0.2"
      fill_in "shipping_rate_card_rate[per_kg_rate_cny]", with: "92.0"
      fill_in "shipping_rate_card_rate[flat_fee_cny]", with: "25.0"
      click_button I18n.t("shipping_rate_cards.add_band")
    end

    expect(page).to have_content("92.0")

    rate = ShippingRateCardRate.last
    rate_dom_id = ActionView::RecordIdentifier.dom_id(rate)
    within("##{rate_dom_id}") do
      find("span[data-cell-edit-target='display']", text: "92.0").click
      input = find("input[type='number']")
      input.set("100.0")
      input.send_keys(:enter)
    end

    # Wait for Turbo Stream to replace the row and the new span to appear
    expect(page).to have_css("##{rate_dom_id} span[data-cell-edit-target='display']", text: "100.0", wait: 10)
    expect(rate.reload.per_kg_rate_cny).to eq(100.0)
  end
end
