require "rails_helper"

RSpec.describe ParcelEstimateComparator do
  let(:company)  { create(:company) }
  let(:user)     { create(:user) }
  let(:store) do
    create(:shopify_store, user: user, company: company,
           currency: "USD", cost_fx_rate: 7.0, default_service_type: "with_battery")
  end
  let(:customer) { create(:customer, shopify_store: store) }

  # An AU order (zone "1"), single line item weighing 2.5kg, priced against a
  # single 0..5kg band (per_kg 30, flat 25, + ¥2 operation fee per parcel):
  #   order estimate  = 2.5 * 30 + 25 + 2 = 102 CNY  → 102 / 7.0 = 14.57 USD
  # Split into two parcels whose billed weights sum back to the SAME 2.5kg
  # (so the split cost is pure "extra flat fee", not a weight discrepancy):
  #   P1 1.5kg → 1.5*30+25+2 = 72 CNY   actual 80 CNY (over by 8)
  #   P2 1.0kg → 1.0*30+25+2 = 57 CNY   actual 50 CNY (under by 7)
  #   Σestimate = 129 CNY   Σactual = 130 CNY
  #   split_cost = 129 - 102 = 27 (the second flat fee + the two ¥2 operation fees)
  #   overcharge = 130 - 129 = 1
  #   invariant: 27 + 1 = 28 = 130 - 102 ✓ (both terms non-zero, non-vacuous)
  def build_zoned_order(weight_grams: 2500, zip: "2075")
    order = create(:order, customer: customer, shopify_store: store,
                   ordered_at: store.active_timezone.local(2026, 4, 15, 12),
                   shopify_data: { "shipping_address" => { "country_code" => "AU", "zip" => zip } })
    product = create(:product, shopify_store: store)
    variant = create(:product_variant, product: product, weight_grams: weight_grams)
    create(:order_line_item, order: order, product_variant: variant, quantity: 1)
    order
  end

  before do
    create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "1", postal_start: "2000", postal_end: "2079")
    create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "2", postal_start: "2080", postal_end: "2084")
    version = create(:shipping_rate_card_version, company: company, country_code: "AU",
                     service_type: "with_battery", effective_from: Date.new(2026, 1, 1))
    create(:shipping_rate_card_rate, version: version, zone: "1", weight_min_kg: 0, weight_max_kg: 5, per_kg_rate_cny: 30, flat_fee_cny: 25)
    create(:shipping_rate_card_rate, version: version, zone: "2", weight_min_kg: 0, weight_max_kg: 5, per_kg_rate_cny: 40, flat_fee_cny: 35)
  end

  describe "worked example: per-parcel pricing and the decomposition invariant" do
    let!(:order) { build_zoned_order }
    let!(:p1) do
      create(:parcel, shopify_store: store, order: order, identifier: "P1", zone: "1",
             billed_weight_g: 1500, cost_cny: 80, fx_rate_snapshot: 7.2, cost_amount: (80 / 7.2).round(2))
    end
    let!(:p2) do
      create(:parcel, shopify_store: store, order: order, identifier: "P2", zone: "1",
             billed_weight_g: 1000, cost_cny: 50, fx_rate_snapshot: 7.2, cost_amount: (50 / 7.2).round(2))
    end

    subject(:result) { described_class.new(order).call }

    it "prices each parcel as per_kg * billed_kg + flat_fee, exactly" do
      line1 = result.parcel_lines.find { |l| l.parcel == p1 }
      line2 = result.parcel_lines.find { |l| l.parcel == p2 }

      expect(line1.estimate_cny).to eq(72)   # 1.5 * 30 + 25 + 2
      expect(line2.estimate_cny).to eq(57)   # 1.0 * 30 + 25 + 2
      expect(line1.estimate).to eq((72 / 7.0).round(2))
      expect(line2.estimate).to eq((57 / 7.0).round(2))
    end

    it "computes the order-level estimate via the shared Basis" do
      expect(result.order_estimate_cny).to eq(102)
      expect(result.order_estimate).to eq(14.57)
      expect(result.estimated_zone).to eq("1")
      expect(result.zoned).to be true
    end

    it "satisfies the money invariant: split_cost + overcharge == actual_total - order_estimate, with both terms non-trivial" do
      expect(result.decomposable).to be true
      expect(result.parcels_estimate_cny).to eq(129)
      expect(result.actual_total_cny).to eq(130)

      expect(result.split_cost_cny).to eq(27)
      expect(result.overcharge_cny).to eq(1)
      expect(result.split_cost_cny).not_to eq(result.overcharge_cny) # both non-zero and distinct — not vacuous

      expect(result.split_cost_cny + result.overcharge_cny)
        .to eq(result.actual_total_cny - result.order_estimate_cny)
    end

    it "matches ShippingCostCalculator.estimate(order) (refactor did not change the order-level number)" do
      expect(ShippingCostCalculator.estimate(order)).to eq(14.57)
      expect(ShippingCostCalculator.estimate(order)).to eq(result.order_estimate)
    end

    it "reports no zone mismatch when billed zones match the estimated zone" do
      expect(result.parcel_lines).to all(have_attributes(zone_mismatch: false))
      expect(result.any_zone_mismatch).to be false
    end
  end

  describe "zone mismatch detection" do
    it "flags a parcel whose billed zone differs from the order's estimated zone" do
      order = build_zoned_order
      matching = create(:parcel, shopify_store: store, order: order, identifier: "M1", zone: "1",
                        billed_weight_g: 1000, cost_cny: 55, fx_rate_snapshot: 7.2, cost_amount: 7.64)
      mismatched = create(:parcel, shopify_store: store, order: order, identifier: "M2", zone: "2",
                          billed_weight_g: 1500, cost_cny: 85, fx_rate_snapshot: 7.2, cost_amount: 11.81)

      result = described_class.new(order).call

      match_line = result.parcel_lines.find { |l| l.parcel == matching }
      mismatch_line = result.parcel_lines.find { |l| l.parcel == mismatched }

      expect(match_line.zone_mismatch).to be false
      expect(mismatch_line.zone_mismatch).to be true
      expect(mismatch_line.billed_zone).to eq("2")
      expect(result.any_zone_mismatch).to be true
    end

    it "does not flag a mismatch for an unzoned country even when the parcel carries a zone value" do
      order = create(:order, customer: customer, shopify_store: store,
                     ordered_at: store.active_timezone.local(2026, 4, 15, 12),
                     shopify_data: { "shipping_address" => { "country_code" => "US" } })
      product = create(:product, shopify_store: store)
      variant = create(:product_variant, product: product, weight_grams: 300)
      create(:order_line_item, order: order, product_variant: variant, quantity: 1)
      create(:shipping_rate_card_version, company: company, country_code: "US",
             service_type: "with_battery", effective_from: Date.new(2026, 1, 1))
             .rates.create!(weight_min_kg: 0.201, weight_max_kg: 0.45, per_kg_rate_cny: 92.0, flat_fee_cny: 23.0)
      parcel = create(:parcel, shopify_store: store, order: order, identifier: "U1", zone: "1",
                      billed_weight_g: 300, cost_cny: 50.6, fx_rate_snapshot: 7.0, cost_amount: 7.23)

      result = described_class.new(order).call

      expect(result.zoned).to be false
      expect(result.estimated_zone).to be_nil
      line = result.parcel_lines.find { |l| l.parcel == parcel }
      expect(line.zone_mismatch).to be false
      expect(result.any_zone_mismatch).to be false
    end
  end

  describe "when a parcel is missing its billed weight" do
    it "marks the order non-decomposable and produces no wrong split/overcharge numbers" do
      order = build_zoned_order
      priced = create(:parcel, shopify_store: store, order: order, identifier: "PW1", zone: "1",
                      billed_weight_g: 1000, cost_cny: 55, fx_rate_snapshot: 7.2, cost_amount: 7.64)
      unpriced = create(:parcel, shopify_store: store, order: order, identifier: "PW2", zone: "1",
                        billed_weight_g: nil, cost_cny: 50, fx_rate_snapshot: 7.2, cost_amount: 6.94)

      result = described_class.new(order).call

      priced_line = result.parcel_lines.find { |l| l.parcel == priced }
      unpriced_line = result.parcel_lines.find { |l| l.parcel == unpriced }

      expect(priced_line.estimate_cny).to eq(57)
      expect(unpriced_line.estimate_cny).to be_nil
      expect(unpriced_line.variance_cny).to be_nil
      expect(unpriced_line.variance_pct).to be_nil

      expect(result.decomposable).to be false
      # Sum of the known ones only — never silently wrong, never a full total either.
      expect(result.parcels_estimate_cny).to eq(57)
      expect(result.split_cost_cny).to be_nil
      expect(result.overcharge_cny).to be_nil
    end
  end

  describe "remote-fee reconciliation (estimated vs billed remote_area_fee_cny)" do
    # A GB order priced against an unzoned rate card with a remote-area rule
    # so every parcel's basis carries a non-zero remote_surcharge_cny — the
    # comparator must then diff that per-parcel estimate against whatever the
    # carrier actually billed as remote_area_fee_cny on each parcel.
    let(:gb_company) { create(:company) }
    let(:gb_store) do
      create(:shopify_store, user: create(:user), company: gb_company, currency: "USD",
             cost_fx_rate: 7.0, default_service_type: "with_battery")
    end
    let(:gb_customer) { create(:customer, shopify_store: gb_store) }

    def gb_remote_order(zip: "IV1 1AA", grams: 1000)
      o = create(:order, customer: gb_customer, shopify_store: gb_store,
                 ordered_at: 1.day.ago,
                 shopify_data: { "shipping_address" => { "country_code" => "GB", "zip" => zip } })
      variant = create(:product_variant, product: create(:product, shopify_store: gb_store), weight_grams: grams)
      create(:order_line_item, order: o, product_variant: variant, quantity: 1)
      o
    end

    before do
      v = create(:shipping_rate_card_version, company: gb_company, country_code: "GB",
                 service_type: "with_battery", effective_from: Date.new(2020, 1, 1))
      create(:shipping_rate_card_rate, version: v, zone: nil, weight_min_kg: 0, weight_max_kg: 5,
             per_kg_rate_cny: 50, flat_fee_cny: 30)
      rav = create(:shipping_remote_area_version, company: gb_company, country_code: "GB",
                   effective_from: Date.new(2020, 1, 1))
      create(:shipping_remote_area_rule, version: rav, postal_start: "IV00", postal_end: "IV99",
             surcharge_cny: 17, area_label: "area 2")
    end

    it "Case A: flags a mismatch when the carrier billed a remote fee for a non-remote parcel (estimate 0, actual > 0)" do
      order = gb_remote_order(zip: "M1 1AA") # not remote -> estimate's remote surcharge is 0
      parcel = create(:parcel, shopify_store: gb_store, order: order, identifier: "RF-A1",
                      billed_weight_g: 1000, cost_cny: 92, fx_rate_snapshot: 7.0, cost_amount: 13.14,
                      remote_area_fee_cny: 10)

      result = described_class.new(order).call
      line = result.parcel_lines.find { |l| l.parcel == parcel }

      expect(line.est_remote_cny).to eq(0)
      expect(line.actual_remote_cny).to eq(10)
      expect(line.remote_mismatch).to be true
      expect(result.any_remote_mismatch).to be true
      expect(result.est_remote_total_cny).to eq(0)
      expect(result.actual_remote_total_cny).to eq(10)
      expect(result.remote_relevant).to be true
    end

    it "Case B: flags a mismatch when the billed remote fee differs from the estimated one (both > 0)" do
      order = gb_remote_order(zip: "IV1 1AA") # remote -> estimate carries the ¥17 surcharge
      parcel = create(:parcel, shopify_store: gb_store, order: order, identifier: "RF-B1",
                      billed_weight_g: 1000, cost_cny: 106, fx_rate_snapshot: 7.0, cost_amount: 15.14,
                      remote_area_fee_cny: 24)

      result = described_class.new(order).call
      line = result.parcel_lines.find { |l| l.parcel == parcel }

      expect(line.est_remote_cny).to eq(17)
      expect(line.actual_remote_cny).to eq(24)
      expect(line.remote_mismatch).to be true
      expect(result.any_remote_mismatch).to be true
      expect(result.remote_area_label).to eq("area 2")
    end

    it "Case C: does not flag a mismatch when the billed remote fee matches the estimate exactly (both > 0)" do
      order = gb_remote_order(zip: "IV1 1AA")
      parcel = create(:parcel, shopify_store: gb_store, order: order, identifier: "RF-C1",
                      billed_weight_g: 1000, cost_cny: 99, fx_rate_snapshot: 7.0, cost_amount: 14.14,
                      remote_area_fee_cny: 17)

      result = described_class.new(order).call
      line = result.parcel_lines.find { |l| l.parcel == parcel }

      expect(line.remote_mismatch).to be false
      expect(result.any_remote_mismatch).to be false
      expect(result.remote_relevant).to be true
      expect(result.est_remote_total_cny).to eq(17)
      expect(result.actual_remote_total_cny).to eq(17)
    end

    it "Case D: is not remote-relevant when neither side ever charges a remote fee" do
      order = gb_remote_order(zip: "M1 1AA") # not remote
      parcel = create(:parcel, shopify_store: gb_store, order: order, identifier: "RF-D1",
                      billed_weight_g: 1000, cost_cny: 82, fx_rate_snapshot: 7.0, cost_amount: 11.71,
                      remote_area_fee_cny: 0)

      result = described_class.new(order).call
      line = result.parcel_lines.find { |l| l.parcel == parcel }

      expect(line.est_remote_cny).to eq(0)
      expect(line.actual_remote_cny).to eq(0)
      expect(line.remote_mismatch).to be false
      expect(result.any_remote_mismatch).to be false
      expect(result.remote_relevant).to be false
      expect(result.est_remote_total_cny).to eq(0)
      expect(result.actual_remote_total_cny).to eq(0)
    end

    it "treats a nil remote_area_fee_cny on the parcel as 0 (bill import may leave it unset)" do
      order = gb_remote_order(zip: "M1 1AA")
      parcel = create(:parcel, shopify_store: gb_store, order: order, identifier: "RF-NIL1",
                      billed_weight_g: 1000, cost_cny: 82, fx_rate_snapshot: 7.0, cost_amount: 11.71,
                      remote_area_fee_cny: nil)

      result = described_class.new(order).call
      line = result.parcel_lines.find { |l| l.parcel == parcel }

      expect(line.actual_remote_cny).to eq(0)
      expect(line.remote_mismatch).to be false
    end

    it "is not remote-mismatched (or relevant) when the order has no basis at all" do
      order = create(:order, customer: gb_customer, shopify_store: gb_store,
                     ordered_at: 1.day.ago, shopify_data: {}) # no country -> no basis
      parcel = create(:parcel, shopify_store: gb_store, order: order, identifier: "RF-NB1",
                      billed_weight_g: 1000, cost_cny: 50, fx_rate_snapshot: 7.0, cost_amount: 7.14,
                      remote_area_fee_cny: 10) # can't tell if this is right or wrong without a basis

      result = described_class.new(order).call
      line = result.parcel_lines.find { |l| l.parcel == parcel }

      expect(line.est_remote_cny).to be_nil
      expect(line.remote_mismatch).to be false
      expect(result.any_remote_mismatch).to be false
      expect(result.remote_relevant).to be false
      expect(result.est_remote_total_cny).to eq(0)
      expect(result.remote_area_label).to be_nil
    end
  end

  describe "when the order itself is not estimable (no basis)" do
    it "returns nil order estimate and nil per-parcel estimates without raising" do
      order = create(:order, customer: customer, shopify_store: store,
                     ordered_at: store.active_timezone.local(2026, 4, 15, 12),
                     shopify_data: {}) # no country → no basis
      parcel = create(:parcel, shopify_store: store, order: order, identifier: "NB1",
                      billed_weight_g: 1000, cost_cny: 55, fx_rate_snapshot: 7.2, cost_amount: 7.64)

      result = described_class.new(order).call

      expect(result.order_estimate_cny).to be_nil
      expect(result.order_estimate).to be_nil
      expect(result.estimated_zone).to be_nil
      expect(result.zoned).to be false
      expect(result.decomposable).to be false
      line = result.parcel_lines.find { |l| l.parcel == parcel }
      expect(line.estimate_cny).to be_nil
      expect(line.zone_mismatch).to be false
    end
  end
end
