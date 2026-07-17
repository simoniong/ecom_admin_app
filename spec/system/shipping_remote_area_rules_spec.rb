require "rails_helper"

RSpec.describe "Remote area rules", type: :system do
  let(:user) { create(:user) }

  before { sign_in_as(user) }

  it "batch-imports pasted rules and shows them" do
    v = create(:shipping_remote_area_version, company: user.companies.first, country_code: "GB", name: "UK v1")
    visit shipping_remote_area_versions_path

    fill_in "text_#{v.id}", with: "AB35, area 3, 10\nIV, area 2, 17"
    click_button "import_#{v.id}"

    expect(page).to have_content("area 2")
    expect(page).to have_content("area 3")
    expect(v.reload.rules.count).to eq(2)
  end

  it "creates a version and adds a single rule" do
    visit shipping_remote_area_versions_path

    within("div.bg-white.border.border-gray-200.rounded-lg.shadow-sm.p-5.mb-6") do
      fill_in "shipping_remote_area_version[name]", with: "UK Remote v2"
      find("select[name='shipping_remote_area_version[country_code]'] option[value='GB']").select_option
      find("input[name='shipping_remote_area_version[effective_from]']").send_keys("06012026")
      click_button I18n.t("remote_areas.create_version")
    end

    expect(page).to have_content("UK Remote v2")

    version = ShippingRemoteAreaVersion.last

    within("##{ActionView::RecordIdentifier.dom_id(version)}") do
      fill_in "shipping_remote_area_rule[postal_start]", with: "AB35"
      fill_in "shipping_remote_area_rule[postal_end]", with: "AB35"
      fill_in "shipping_remote_area_rule[area_label]", with: "area 3"
      fill_in "shipping_remote_area_rule[surcharge_cny]", with: "10"
      click_button I18n.t("remote_areas.add_rule")
    end

    expect(page).to have_content("area 3")
  end
end
