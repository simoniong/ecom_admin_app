require "rails_helper"

RSpec.describe "Dashboard shipping section", type: :request do
  let(:user)    { create(:user) }
  let(:company) { user.companies.first }
  let(:store)   { create(:shopify_store, user: user, company: company, cost_fx_rate: 7.2, timezone: "UTC") }
  let(:customer) { create(:customer, shopify_store: store) }

  before { sign_in user }

  it "renders the shipping section with a link into the variance report" do
    order = create(:order, customer: customer, shopify_store: store, name: "PKS#3052",
                           estimated_shipping_cost: 18.20, ordered_at: 1.day.ago)
    create(:parcel, shopify_store: store, order: order, identifier: "B1", cost_amount: 20)
    create(:parcel, shopify_store: store, order: order, identifier: "B2", cost_amount: 20.10)

    get authenticated_root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("dashboard.section_shipping"))
    expect(response.body).to include(I18n.t("dashboard.view_variance"))
    expect(response.body).to include("sort_column=variance")

    # The link must carry the dashboard's current date range into the variance
    # report — without it, "view variance detail" would silently reset to the
    # report's own default range instead of the one the user is looking at.
    range = DashboardMetricsService.new(company, range_key: "past_7_days").call[:date_range]
    expect(response.body).to include("from_date=#{range.first}")
    expect(response.body).to include("to_date=#{range.last}")
  end
end
