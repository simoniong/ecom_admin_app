require "rails_helper"

RSpec.describe "Logistics Channels", type: :system do
  let!(:user) { create(:user) }
  let(:company) { user.companies.first }

  before do
    create(:logistics_account, company: company, url1_base: "http://raydo.test:8082")
    stub_request(:get, "http://raydo.test:8082/getProductList.htm")
      .to_return(body: [
        { product_id: "P1", product_shortname: "UK Small Packet" },
        { product_id: "P2", product_shortname: "US Small Packet" }
      ].to_json, headers: { "Content-Type" => "application/json" })
  end

  it "creates a channel by picking a product from the live Raydo dropdown" do
    sign_in_as(user)
    navigate_to_settings_item "Logistics Channels", group: "Shipping"

    click_link "New Channel"

    select "US Small Packet", from: "logistics_channel[product_id]"
    fill_in "logistics_channel[name]", with: "US Line"

    click_button "Save"

    expect(page).to have_text("Logistics channel created.")
    expect(page).to have_text("US Line")
    expect(page).to have_text("US Small Packet")
  end
end
