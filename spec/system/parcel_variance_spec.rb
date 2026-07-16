require "rails_helper"

RSpec.describe "Shipping variance report", type: :system do
  let(:user)     { create(:user) }
  let(:company)  { user.companies.first }
  let!(:store)   { create(:shopify_store, user: user, company: company, cost_fx_rate: 7.2, timezone: "UTC") }
  let(:customer) { create(:customer, shopify_store: store) }

  let!(:blown) do
    o = create(:order, customer: customer, shopify_store: store, name: "PKS#3052",
                        estimated_shipping_cost: 18.20, ordered_at: 1.day.ago)
    create(:parcel, shopify_store: store, order: o, identifier: "B1", cost_cny: 144, cost_amount: 20)
    create(:parcel, shopify_store: store, order: o, identifier: "B2", cost_cny: 144.72, cost_amount: 20.10)
    o
  end

  before { sign_in_as(user) }

  it "navigates from the dashboard into the variance report, worst overrun first" do
    # A second order with a much smaller overrun — proves the dashboard link's
    # sort_column=variance&sort_direction=desc actually lands on a sorted page,
    # not just any page that happens to contain both orders.
    light = create(:order, customer: customer, shopify_store: store, name: "PKS#4001",
                            estimated_shipping_cost: 20, ordered_at: 1.day.ago)
    create(:parcel, shopify_store: store, order: light, identifier: "L1", cost_cny: 151.2, cost_amount: 21)

    visit authenticated_root_path
    click_link I18n.t("dashboard.view_variance")

    expect(page).to have_content(I18n.t("parcels.title"))
    expect(page).to have_content("PKS#3052")
    expect(page).to have_content("PKS#4001")

    # blown has the bigger variance (21.90 vs 1.00) and must sort first under
    # the desc-by-variance ordering the dashboard link requests.
    expect(page.text.index("PKS#3052")).to be < page.text.index("PKS#4001")

    # The per-parcel detail (identifiers, per-parcel estimate/variance) is
    # collapsed by default — only visible once the order row is expanded.
    find("tr", text: "PKS#3052").click
    expect(page).to have_content("B1")
    expect(page).to have_content("B2")
  end

  it "edits a parcel cost inline via Turbo Stream and re-rolls up the order" do
    parcel = Parcel.find_by!(shopify_store: store, identifier: "B1")

    visit parcels_path
    find("tr", text: "PKS#3052").click
    # Inline edit controls are hidden by default and gated behind the
    # page-level "編輯模式" checkbox — see edit_mode_controller.js.
    check I18n.t("parcels.edit_mode")

    within("##{ActionView::RecordIdentifier.dom_id(parcel)}") do
      find("input[aria-label='#{I18n.t('parcels.columns.cost_cny')}']").set("72.00")
      click_button I18n.t("parcels.save")
    end

    # The updated converted amount (72 / 7.2 = 10.00) must appear in the row,
    # and it must be delivered via the turbo_stream partial replace rather
    # than a full-page redirect: the format.html branch sets a flash notice
    # that format.turbo_stream never does, so its absence proves the real
    # Turbo Stream response path (app/views/parcels/update.turbo_stream.erb)
    # was exercised, not the html fallback.
    within("##{ActionView::RecordIdentifier.dom_id(parcel)}") do
      expect(page).to have_content("$10.00")
    end
    expect(page).not_to have_content(I18n.t("parcels.updated"))

    expect(blown.reload.actual_shipping_cost).to eq(30.10) # 10.00 + 20.10
  end

  # The inline edit controls (cost input + save + delete) must stay hidden
  # until the operator opts in via "編輯模式" — accidentally deleting or
  # overwriting a billed cost from a report that's mostly read-only is the
  # failure mode this gate exists to prevent. The controls must still exist
  # in the DOM (not be gone entirely) once toggled on.
  it "hides the inline edit controls by default and reveals them once edit mode is switched on" do
    parcel = Parcel.find_by!(shopify_store: store, identifier: "B1")

    visit parcels_path
    find("tr", text: "PKS#3052").click

    within("##{ActionView::RecordIdentifier.dom_id(parcel)}") do
      expect(page).to have_css(".parcels-edit-col", visible: :hidden)
      expect(page).not_to have_css(".parcels-edit-col", visible: :visible)
    end

    check I18n.t("parcels.edit_mode")

    within("##{ActionView::RecordIdentifier.dom_id(parcel)}") do
      expect(page).to have_css(".parcels-edit-col", visible: :visible)
      expect(page).to have_button(I18n.t("parcels.save"))
    end

    uncheck I18n.t("parcels.edit_mode")

    within("##{ActionView::RecordIdentifier.dom_id(parcel)}") do
      expect(page).not_to have_css(".parcels-edit-col", visible: :visible)
    end
  end

  it "assigns an unmatched parcel to an order and the rollup follows" do
    orphan = create(:parcel, shopify_store: store, order: nil, identifier: "ORPHAN1", cost_amount: 5)

    visit parcels_path(tab: "unmatched")
    expect(page).to have_content("ORPHAN1")

    select "PKS#3052", from: "parcel[order_id]"
    click_button I18n.t("parcels.assign")

    # The parcel is no longer unmatched, so its row must leave this tab without
    # a reload — the Turbo Stream `remove` actually landing on a real element.
    # Before the dom_id fix the row had no id, the stream matched nothing, and
    # the page sat there silently showing a parcel that was already assigned.
    expect(page).not_to have_css("##{ActionView::RecordIdentifier.dom_id(orphan)}")
    expect(page).not_to have_content("ORPHAN1")

    expect(orphan.reload.order_id).to eq(blown.id)
    expect(blown.reload.actual_shipping_cost).to eq(45.10) # 20 + 20.10 + 5
  end

  # The unmatched-tab dropdown is populated client-side by
  # lazy_options_controller.js cloning a shared <template> (kept off the
  # per-row markup to avoid rows × orders page weight — see the request spec
  # in spec/requests/parcels_spec.rb for that measurement). This drives the
  # real dropdown through headless Chrome to prove an order far beyond the
  # old 200-row dropdown cap is genuinely selectable and assignable end to
  # end, not merely present somewhere in the raw HTML.
  it "assigns an unmatched parcel to an order far beyond the old 200-row dropdown cap" do
    orphan = create(:parcel, shopify_store: store, order: nil, identifier: "ORPHANFAR", cost_amount: 5)
    distant = nil
    205.times do |i|
      o = create(:order, customer: customer, shopify_store: store, name: "PKS#FAR#{i}", ordered_at: (i + 1).days.ago)
      distant = o if i == 204
    end

    visit parcels_path(tab: "unmatched")
    expect(page).to have_content("ORPHANFAR")

    select distant.name, from: "parcel[order_id]"
    click_button I18n.t("parcels.assign")

    expect(page).not_to have_content("ORPHANFAR")
    expect(orphan.reload.order_id).to eq(distant.id)
    expect(distant.reload.actual_shipping_cost).to eq(5)
  end
end
