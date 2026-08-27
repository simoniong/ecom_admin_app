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

  # A single parcel weighed lighter than the goods on the order. Both labels on
  # this screen used to misdescribe it: the weight badge said "matches" (its
  # check only ever detected a HEAVIER parcel) and the reconciliation credited
  # the resulting gap to "split cost" even though nothing was split. Production
  # order PKS#4113 showed exactly this — 1.207 kg billed against 1.26 kg of
  # goods, labelled as matching, with the ¥4.88 difference called a split cost.
  describe "a parcel lighter than the order contents" do
    let!(:light_store) do
      create(:shopify_store, user: user, company: company, currency: "USD",
             cost_fx_rate: 7.0, default_service_type: "with_battery", timezone: "UTC")
    end
    let(:light_customer) { create(:customer, shopify_store: light_store) }

    before do
      version = create(:shipping_rate_card_version, company: company, country_code: "US",
                       service_type: "with_battery", effective_from: Date.new(2026, 1, 1))
      create(:shipping_rate_card_rate, version: version, zone: nil,
             weight_min_kg: 0, weight_max_kg: 5, per_kg_rate_cny: 100, flat_fee_cny: 20)

      order = create(:order, customer: light_customer, shopify_store: light_store, name: "PKS#7001",
                     ordered_at: 1.day.ago,
                     shopify_data: { "shipping_address" => { "country_code" => "US" } },
                     estimated_shipping_cost: 17.43) # 1.00 kg -> (100 + 20 + 2) / 7.0
      product = create(:product, shopify_store: light_store)
      [ 600, 400 ].each do |grams|
        variant = create(:product_variant, product: product, weight_grams: grams)
        create(:order_line_item, order: order, product_variant: variant, quantity: 1)
      end
      # Billed 0.95 kg against 1.00 kg of goods: 50 g lighter.
      create(:parcel, shopify_store: light_store, order: order, identifier: "LIGHT1",
             billed_weight_g: 950, cost_cny: 117, cost_amount: 16.71)
    end

    it "labels the parcel as lighter instead of claiming the weights match" do
      visit parcels_path
      find("tr", text: "PKS#7001").click

      # Scoped to the totals row: "· matches estimate basis" elsewhere on the
      # page also contains the word, and is a different (correct) statement.
      within("[data-parcel-totals-row]") do
        expect(page).to have_content("−0.05↓")
        expect(page).not_to have_content(I18n.t("parcels.parcel_table.weight_flat"))
      end
    end

    it "calls the gap a weight difference, not a split cost" do
      visit parcels_path
      find("tr", text: "PKS#7001").click

      expect(page).to have_content(I18n.t("parcels.recon.weight_diff_label"))
      expect(page).not_to have_content(I18n.t("parcels.recon.split_label"))
    end

    it "names the estimate the breakdown is measured against" do
      visit parcels_path
      find("tr", text: "PKS#7001").click

      expect(page).to have_content(I18n.t("parcels.recon.total_label"))
      expect(page).to have_content(I18n.t("parcels.recon.cny_native_note"))
    end
  end
end
