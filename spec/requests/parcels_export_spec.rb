require "rails_helper"
require "roo"

# Task 3 of the estimate-comparison-and-export feature: the reconciliation
# Excel export at GET /parcels/export. One row per PARCEL (not per order),
# CNY as the primary/only currency (no FX column — the carrier bill is
# already denominated in CNY), and it must follow the exact same filter the
# orders tab is currently showing so the export always matches the screen.
RSpec.describe "Parcels export", type: :request do
  let(:user)    { create(:user) }
  let(:company) { user.companies.first }
  let(:store) do
    create(:shopify_store, user: user, company: company, currency: "USD",
           cost_fx_rate: 7.0, default_service_type: "with_battery")
  end
  let(:customer) { create(:customer, shopify_store: store) }

  before do
    sign_in user
    create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "1", postal_start: "2000", postal_end: "2079")
    create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "2", postal_start: "2080", postal_end: "2084")
    version = create(:shipping_rate_card_version, company: company, country_code: "AU",
                      service_type: "with_battery", effective_from: Date.new(2020, 1, 1))
    create(:shipping_rate_card_rate, version: version, zone: "1", weight_min_kg: 0, weight_max_kg: 5, per_kg_rate_cny: 30, flat_fee_cny: 25)
    create(:shipping_rate_card_rate, version: version, zone: "2", weight_min_kg: 0, weight_max_kg: 5, per_kg_rate_cny: 40, flat_fee_cny: 35)
  end

  # An order the comparator can price: AU, zoned postal code, one line item
  # with a real weight so ShippingCostCalculator::Basis resolves. Mirrors
  # the equivalent helper in spec/requests/parcels_spec.rb.
  def priced_order(name:, zip:, weight_grams:, ordered_at: 1.day.ago)
    o = create(:order, customer: customer, shopify_store: store, name: name,
               ordered_at: ordered_at,
               shopify_data: { "shipping_address" => { "country_code" => "AU", "zip" => zip } })
    product = create(:product, shopify_store: store)
    variant = create(:product_variant, product: product, weight_grams: weight_grams)
    create(:order_line_item, order: o, product_variant: variant, quantity: 1)
    o
  end

  # Parses the xlsx response body via roo (real parsing, no mocks) and
  # returns [header_row, *data_rows] as arrays of cell values.
  def parsed_rows
    xlsx = Roo::Excelx.new(StringIO.new(response.body))
    xlsx.default_sheet = xlsx.sheets.first
    (1..xlsx.last_row).map { |i| xlsx.row(i) }
  end

  HEADER = %w[
    order_name identifier internal_no tracking_number shipped_at
    country customer_zip estimated_zone billed_zone zone_match
    actual_weight_g billed_weight_g service_channel
    freight_cny registration_fee_cny tax_cny remote_area_fee_cny operation_fee_cny cost_cny
    estimate_cny variance_cny variance_pct
  ].freeze
  HEADER_TEXT = HEADER.map { |k| I18n.t("parcels.export.#{k}") }.freeze

  it "responds with an xlsx content type and attachment disposition" do
    get export_parcels_path

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    expect(response.headers["Content-Disposition"]).to include("attachment")
    expect(response.headers["Content-Disposition"]).to match(/parcels_reconciliation_\d{8}_\d{6}\.xlsx/)
  end

  it "renders the header row with every field in the specified order and no FX/exchange-rate column" do
    get export_parcels_path

    rows = parsed_rows
    expect(rows.first).to eq(HEADER_TEXT)
    expect(rows.first.join(" ")).not_to match(/fx|汇率|匯率|exchange rate/i)
  end

  it "renders one row per parcel — a multi-parcel order produces multiple rows" do
    order = priced_order(name: "PKS#MULTI", zip: "2075", weight_grams: 2500)
    create(:parcel, shopify_store: store, order: order, identifier: "MULTI1", zone: "1",
           billed_weight_g: 1500, cost_cny: 80, fx_rate_snapshot: 7.0, cost_amount: 11.43)
    create(:parcel, shopify_store: store, order: order, identifier: "MULTI2", zone: "1",
           billed_weight_g: 1000, cost_cny: 50, fx_rate_snapshot: 7.0, cost_amount: 7.14)

    single = priced_order(name: "PKS#SINGLE", zip: "2075", weight_grams: 1000)
    create(:parcel, shopify_store: store, order: single, identifier: "SINGLE1", zone: "1",
           billed_weight_g: 1000, cost_cny: 55, fx_rate_snapshot: 7.0, cost_amount: 7.86)

    get export_parcels_path

    rows = parsed_rows.drop(1) # drop header
    multi_rows = rows.select { |r| r[0] == "PKS#MULTI" }
    single_rows = rows.select { |r| r[0] == "PKS#SINGLE" }

    expect(multi_rows.size).to eq(2)
    expect(multi_rows.map { |r| r[1] }).to contain_exactly("MULTI1", "MULTI2")
    expect(single_rows.size).to eq(1)
  end

  it "takes CNY expense figures from the billed parcel record, the estimated zone from the order's comparator, and the customer zip from the shipping address" do
    order = priced_order(name: "PKS#FIELDS", zip: "2075", weight_grams: 1500) # estimated zone "1"
    parcel = create(:parcel, shopify_store: store, order: order, identifier: "FIELDS1",
                    internal_no: "INTFIELDS1", tracking_number: "TRKFIELDS1",
                    zone: "1", service_channel: "US Standard",
                    actual_weight_g: 1510, billed_weight_g: 1500,
                    freight_cny: 60, registration_fee_cny: 8, tax_cny: 1,
                    remote_area_fee_cny: 0.5, operation_fee_cny: 2,
                    cost_cny: 71.5, fx_rate_snapshot: 7.0, cost_amount: 10.21,
                    shipped_at: Time.utc(2026, 3, 10, 6, 30))

    get export_parcels_path

    row = parsed_rows.find { |r| r[1] == "FIELDS1" }
    data = HEADER.zip(row).to_h

    expect(data["order_name"]).to eq("PKS#FIELDS")
    expect(data["internal_no"]).to eq(parcel.internal_no)
    expect(data["tracking_number"]).to eq(parcel.tracking_number)
    expect(data["customer_zip"]).to eq("2075")
    expect(data["estimated_zone"]).to eq("1")
    expect(data["billed_zone"]).to eq("1")
    expect(data["actual_weight_g"]).to eq(1510)
    expect(data["billed_weight_g"]).to eq(1500)
    expect(data["service_channel"]).to eq("US Standard")
    expect(data["freight_cny"]).to eq(60)
    expect(data["registration_fee_cny"]).to eq(8)
    expect(data["tax_cny"]).to eq(1)
    expect(data["remote_area_fee_cny"]).to eq(0.5)
    expect(data["operation_fee_cny"]).to eq(2)
    expect(data["cost_cny"]).to eq(71.5)
    # estimate: 1.5kg * 30 + 25 = 70 CNY; variance = 71.5 - 70 = 1.5; pct = 1.5/70*100 = 2.14
    expect(data["estimate_cny"]).to eq(70)
    expect(data["variance_cny"]).to eq(1.5)
    expect(data["variance_pct"]).to eq(2.14)
  end

  describe "zone match (Y/N)" do
    it "marks Y when billed zone matches the estimated zone, and N for a mismatch" do
      matched = priced_order(name: "PKS#ZOK", zip: "2075", weight_grams: 1000) # estimated zone "1"
      create(:parcel, shopify_store: store, order: matched, identifier: "ZOK1", zone: "1",
             billed_weight_g: 1000, cost_cny: 55, fx_rate_snapshot: 7.0, cost_amount: 7.86)

      mismatched = priced_order(name: "PKS#ZBAD", zip: "2075", weight_grams: 1000) # estimated zone "1"
      create(:parcel, shopify_store: store, order: mismatched, identifier: "ZBAD1", zone: "2",
             billed_weight_g: 1000, cost_cny: 65, fx_rate_snapshot: 7.0, cost_amount: 9.29)

      get export_parcels_path

      rows = parsed_rows
      ok_row = rows.find { |r| r[1] == "ZOK1" }
      bad_row = rows.find { |r| r[1] == "ZBAD1" }

      expect(ok_row[HEADER.index("zone_match")]).to eq("Y")
      expect(bad_row[HEADER.index("zone_match")]).to eq("N")
    end

    # Mutation-test target: flipping the Y/N ternary in
    # ParcelsController#zone_match_cell must fail exactly the two assertions
    # above (Y <-> N swapped), proving the assertions actually pin the
    # direction of the mapping and not just its presence.
  end

  describe "when the estimate can't be computed" do
    it "leaves the estimated zone, estimate and variance cells blank (not zero) when the order has no shipping zip" do
      order = create(:order, customer: customer, shopify_store: store, name: "PKS#NOZIP",
                     ordered_at: 1.day.ago,
                     shopify_data: { "shipping_address" => { "country_code" => "AU" } }) # no zip
      product = create(:product, shopify_store: store)
      variant = create(:product_variant, product: product, weight_grams: 1000)
      create(:order_line_item, order: order, product_variant: variant, quantity: 1)
      create(:parcel, shopify_store: store, order: order, identifier: "NOZIP1",
             billed_weight_g: 1000, cost_cny: 55, fx_rate_snapshot: 7.0, cost_amount: 7.86)

      get export_parcels_path

      row = parsed_rows.find { |r| r[1] == "NOZIP1" }
      data = HEADER.zip(row).to_h

      expect(data["customer_zip"]).to be_nil
      expect(data["estimated_zone"]).to be_nil
      expect(data["zone_match"]).to be_nil
      # Must be genuinely absent, never coerced to a numeric zero — this is
      # the mutation-test target for the "无法估留空" requirement: swapping
      # `line.estimate_cny` for `line.estimate_cny || 0` (or an order-level
      # figure) in the controller would turn these nils into a real number.
      expect(data["estimate_cny"]).to be_nil
      expect(data["variance_cny"]).to be_nil
      expect(data["variance_pct"]).to be_nil
    end
  end

  describe "follows the current filter" do
    it "excludes an order the over_only filter would exclude from the screen" do
      over = priced_order(name: "PKS#OVEREXP", zip: "2075", weight_grams: 1000)
      over.update!(estimated_shipping_cost: 10)
      create(:parcel, shopify_store: store, order: over, identifier: "OVEREXP1", zone: "1",
             billed_weight_g: 1000, cost_cny: 55, fx_rate_snapshot: 7.0, cost_amount: 20)

      saver = priced_order(name: "PKS#SAVEREXP", zip: "2075", weight_grams: 1000)
      saver.update!(estimated_shipping_cost: 100)
      create(:parcel, shopify_store: store, order: saver, identifier: "SAVEREXP1", zone: "1",
             billed_weight_g: 1000, cost_cny: 55, fx_rate_snapshot: 7.0, cost_amount: 5)

      get export_parcels_path, params: { over_only: "1" }

      names = parsed_rows.drop(1).map { |r| r[0] }
      expect(names).to include("PKS#OVEREXP")
      expect(names).not_to include("PKS#SAVEREXP")
    end

    it "excludes an order outside the from_date/to_date range" do
      in_range = priced_order(name: "PKS#INRANGE", zip: "2075", weight_grams: 1000, ordered_at: 5.days.ago)
      create(:parcel, shopify_store: store, order: in_range, identifier: "INRANGE1", zone: "1",
             billed_weight_g: 1000, cost_cny: 55, fx_rate_snapshot: 7.0, cost_amount: 7.86)

      out_of_range = priced_order(name: "PKS#OUTRANGE", zip: "2075", weight_grams: 1000, ordered_at: 90.days.ago)
      create(:parcel, shopify_store: store, order: out_of_range, identifier: "OUTRANGE1", zone: "1",
             billed_weight_g: 1000, cost_cny: 55, fx_rate_snapshot: 7.0, cost_amount: 7.86)

      get export_parcels_path, params: { from_date: 10.days.ago.to_date.to_s, to_date: Date.current.to_s }

      names = parsed_rows.drop(1).map { |r| r[0] }
      expect(names).to include("PKS#INRANGE")
      expect(names).not_to include("PKS#OUTRANGE")
    end
  end

  describe "access control" do
    it "allows a member with only the parcels permission (no owner role required, unlike update/destroy)" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "parcels" ])
      sign_out user
      sign_in member

      order = priced_order(name: "PKS#MEMBEREXP", zip: "2075", weight_grams: 1000)
      create(:parcel, shopify_store: store, order: order, identifier: "MEMBEREXP1", zone: "1",
             billed_weight_g: 1000, cost_cny: 55, fx_rate_snapshot: 7.0, cost_amount: 7.86)

      get export_parcels_path

      expect(response).to have_http_status(:ok)
    end

    it "denies a member without the parcels permission" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [])
      sign_out user
      sign_in member

      get export_parcels_path

      expect(response).to redirect_to(authenticated_root_path)
    end
  end
end
