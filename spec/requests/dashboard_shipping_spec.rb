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

  # Scope assertions to the shipping section's own markup so they can't be
  # satisfied by the unrelated coverage footnote elsewhere on the dashboard
  # (dashboard/show.html.erb renders its own "actual: X% · estimated: Y%"
  # line using the same shipping_coverage_actual_pct value).
  def shipping_section_fragment(body)
    # Anchor on the "Estimated shipping" metric card title, which only appears
    # once on the page (unlike "Shipping", which also matches sidebar nav
    # entries like "Shipping Rate Cards").
    body[/#{Regexp.escape(I18n.t('dashboard.shipping_estimated'))}.*?<\/section>/m]
  end

  def order_with(estimated:, parcel_costs:, name:)
    o = create(:order, customer: customer, shopify_store: store, name: name,
                       estimated_shipping_cost: estimated, ordered_at: 1.day.ago)
    parcel_costs.each_with_index do |c, i|
      create(:parcel, shopify_store: store, order: o, identifier: "#{name}-#{i}", cost_amount: c)
    end
    o
  end

  it "shows the comparable-set percentage (not the actual-coverage percentage) next to the variance" do
    order_with(estimated: 10, parcel_costs: [ 15 ], name: "PKS#1")  # comparable
    order_with(estimated: 20, parcel_costs: [ 18 ], name: "PKS#2")  # comparable
    order_with(estimated: nil, parcel_costs: [ 99 ], name: "PKS#3") # actual-only — inflates actual-coverage
    create(:order, customer: customer, shopify_store: store, name: "PKS#4",
                   estimated_shipping_cost: 30, ordered_at: 1.day.ago) # estimated-only

    get authenticated_root_path

    fragment = shipping_section_fragment(response.body)

    # comparable = 2/4 = 50.0%; shipping_coverage_actual_pct would be 3/4 = 75.0%.
    expect(fragment).to include("50.0%")
    expect(fragment).not_to include("75.0%")
  end

  it "renders the coverage footnote label, percentage, and caveat text" do
    order_with(estimated: 10, parcel_costs: [ 15 ], name: "PKS#1")
    order_with(estimated: 20, parcel_costs: [ 18 ], name: "PKS#2")

    get authenticated_root_path

    fragment = shipping_section_fragment(response.body)

    expect(fragment).to include(I18n.t("dashboard.shipping_coverage"))
    expect(fragment).to include("100.0%")
    expect(fragment).to include(I18n.t("dashboard.shipping_coverage_caveat"))
  end
end
