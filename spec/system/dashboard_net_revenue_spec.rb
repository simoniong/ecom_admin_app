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

  it "organizes metrics into labeled sections with a revenue waterfall" do
    create(:shopify_daily_metric, shopify_store: store, date: Date.current,
      gross_revenue: 1000, refunds: 100, total_tax: 60, transaction_fees: 40, revenue: 900)

    sign_in_as(user)
    visit authenticated_root_path

    # Section eyebrows use CSS text-transform: uppercase, so match case-insensitively.
    expect(page).to have_content(/#{Regexp.escape(I18n.t("dashboard.section_revenue"))}/i)
    expect(page).to have_content(/#{Regexp.escape(I18n.t("dashboard.section_orders"))}/i)
    expect(page).to have_content(/#{Regexp.escape(I18n.t("dashboard.section_advertising"))}/i)
    expect(page).to have_content(/#{Regexp.escape(I18n.t("dashboard.section_profit"))}/i)
    expect(page).to have_content(I18n.t("dashboard.net_revenue_badge"))

    # Waterfall shows both the intermediate Revenue (900) and Net Revenue (800)
    expect(page).to have_content(ActionController::Base.helpers.number_to_currency(900))
    expect(page).to have_content(ActionController::Base.helpers.number_to_currency(800))
  end
end
