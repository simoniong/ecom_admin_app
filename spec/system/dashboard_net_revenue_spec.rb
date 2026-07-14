require "rails_helper"

RSpec.describe "Dashboard net revenue breakdown", type: :system do
  let!(:user) { create(:user) }
  let!(:store) { create(:shopify_store, user: user) }

  it "shows the net revenue breakdown cards" do
    create(:shopify_daily_metric, shopify_store: store, date: Date.current,
      gross_revenue: 1000, refunds: 100, total_tax: 60, transaction_fees: 40, revenue: 900)

    sign_in_as(user)
    visit authenticated_root_path

    expect(page).to have_content(I18n.t("dashboard.net_revenue"))
    expect(page).to have_content(I18n.t("dashboard.gross_revenue"))
    expect(page).to have_content(I18n.t("dashboard.transaction_fees"))
    expect(page).to have_content(I18n.t("dashboard.transaction_fees_note"))
    expect(page).to have_content(ActionController::Base.helpers.number_to_currency(800))
  end
end
