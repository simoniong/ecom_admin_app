require "rails_helper"

RSpec.describe "Postal zones", type: :system do
  let(:owner) { create(:user) }

  before { sign_in_as(owner) }

  it "imports an AU postal map and shows the summary" do
    visit shipping_zone_postal_rules_path

    find("select[name='country_code'] option[value='AU']").select_option
    fill_in "text", with: "1: 2000-2079, 2158\n2: 2080-2084"
    click_button I18n.t("shipping_zone_postal_rules.import_button")

    expect(page).to have_content(I18n.t("shipping_zone_postal_rules.imported", count: 3, country: "AU"))
    company = owner.companies.first
    expect(company.shipping_zone_postal_rules.where(country_code: "AU").count).to eq(3)
    expect(page).to have_content("zone 1")
  end
end
