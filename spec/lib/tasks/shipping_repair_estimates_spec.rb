require "rails_helper"
require "rake"

RSpec.describe "shipping:repair_estimates", type: :task do
  before(:all) do
    Rake.application.rake_require("tasks/shipping", [ Rails.root.join("lib").to_s ])
    Rake::Task.define_task(:environment)
  end

  let(:task) { Rake::Task["shipping:repair_estimates"] }

  before do
    task.reenable
    %w[APPLY FROM STORE].each { |k| ENV.delete(k) }
  end

  after { %w[APPLY FROM STORE].each { |k| ENV.delete(k) } }

  let(:company) { create(:company) }
  let(:user)    { create(:user) }
  let(:store) do
    create(:shopify_store, user: user, company: company,
           currency: "USD", cost_fx_rate: 7.0, default_service_type: "with_battery")
  end
  let(:customer) { create(:customer, shopify_store: store) }
  let(:product)  { create(:product, shopify_store: store) }

  before do
    version = create(:shipping_rate_card_version, company: company, country_code: "US",
                     service_type: "with_battery", effective_from: Date.new(2026, 1, 1))
    create(:shipping_rate_card_rate, version: version, zone: nil,
           weight_min_kg: 0, weight_max_kg: 5, per_kg_rate_cny: 10, flat_fee_cny: 23)
  end

  def usd_for(weight_kg)
    ((BigDecimal(weight_kg.to_s) * 10 + 23 + 2) / 7.0).round(2)
  end

  def build_order(weights_grams:, estimated_shipping_cost:)
    order = create(:order, customer: customer, shopify_store: store,
                   ordered_at: Time.utc(2026, 4, 15, 12),
                   shopify_data: { "shipping_address" => { "country_code" => "US" } },
                   estimated_shipping_cost: estimated_shipping_cost)
    weights_grams.each_with_index do |grams, i|
      variant = create(:product_variant, product: product, weight_grams: grams)
      create(:order_line_item, order: order, product_variant: variant, quantity: 1,
             weight_grams_snapshot: grams, created_at: Time.utc(2026, 4, 15, 12, 0, i))
    end
    order
  end

  it "groups the report by which proof succeeded and writes nothing without APPLY" do
    partial = build_order(weights_grams: [ 800, 400 ], estimated_shipping_cost: usd_for(0.8))
    fee = build_order(weights_grams: [ 800 ],
                      estimated_shipping_cost: ((BigDecimal("0.8") * 10 + 23) / 7.0).round(2))

    expect { task.invoke }.to output(
      match(/DRY RUN/)
        .and(match(/repairable=2 unexplained=0/))
        .and(match(/partial_order: 1/))
        .and(match(/operation_fee: 1/))
        .and(match(/#{Regexp.escape(partial.name)}.*priced 1\/2 items/))
        .and(match(/#{Regexp.escape(fee.name)}.*missing 1 × ¥2 handling fee/))
    ).to_stdout

    expect(partial.reload.estimated_shipping_cost).to eq(usd_for(0.8))
    expect(fee.reload.estimated_shipping_cost).not_to eq(usd_for(0.8))
  end

  it "writes both repairs with APPLY=1" do
    partial = build_order(weights_grams: [ 800, 400 ], estimated_shipping_cost: usd_for(0.8))
    fee = build_order(weights_grams: [ 800 ],
                      estimated_shipping_cost: ((BigDecimal("0.8") * 10 + 23) / 7.0).round(2))
    ENV["APPLY"] = "1"

    expect { task.invoke }.to output(match(/APPLIED/)).to_stdout

    expect(partial.reload.estimated_shipping_cost).to eq(usd_for(1.2))
    expect(fee.reload.estimated_shipping_cost).to eq(usd_for(0.8))
  end

  it "lists an unprovable order under Unexplained and leaves it untouched" do
    order = build_order(weights_grams: [ 800, 400 ], estimated_shipping_cost: 99.99)
    ENV["APPLY"] = "1"

    expect { task.invoke }.to output(
      match(/Unexplained/).and(match(/#{Regexp.escape(order.name)}\s+frozen=99\.99/))
    ).to_stdout

    expect(order.reload.estimated_shipping_cost).to eq(99.99)
  end

  it "aborts on a malformed FROM instead of scanning everything" do
    ENV["FROM"] = "not-a-date"

    expect { task.invoke }.to raise_error(SystemExit).and output(/must be an ISO date/).to_stderr
  end
end
