require "rails_helper"

RSpec.describe ParcelUpserter do
  let(:user)  { create(:user) }
  let(:store) { create(:shopify_store, user: user, company: user.companies.first, cost_fx_rate: 7.2) }
  let(:customer) { create(:customer, shopify_store: store) }
  let!(:order)   { create(:order, customer: customer, shopify_store: store, name: "PKS#3037") }

  def attrs(over = {})
    {
      identifier: "XMBDE2012381",
      order_name: "PKS#3037",
      internal_no: "DOR0201415428CN",
      tracking_number: "SPXORH011122606010001237",
      shipped_at: Time.utc(2026, 6, 1, 21, 48, 26),
      service_channel: "美国标准（A带电）",
      zone: nil,
      country: "美国",
      actual_weight_g: 2423,
      billed_weight_g: 2421,
      cost_cny: BigDecimal("239.73"),
      freight_cny: BigDecimal("222.73"),
      registration_fee_cny: BigDecimal("15"),
      tax_cny: BigDecimal("0"),
      remote_area_fee_cny: BigDecimal("0"),
      operation_fee_cny: BigDecimal("2")
    }.merge(over)
  end

  it "creates a parcel, converts CNY to store currency and snapshots the fx rate" do
    parcel = described_class.new(store: store, attrs: attrs).call

    expect(parcel).to be_persisted
    expect(parcel.order).to eq(order)
    expect(parcel.fx_rate_snapshot).to eq(7.2)
    expect(parcel.cost_amount).to eq(BigDecimal("33.30"))   # 239.73 / 7.2 = 33.2958…
    expect(order.reload.actual_shipping_cost).to eq(BigDecimal("33.30"))

    # Reload from the DB (not just the in-memory object returned by #call) so this
    # actually fails if the rate were assigned after save! instead of before it.
    expect(parcel.reload.fx_rate_snapshot).to eq(BigDecimal("7.2"))
  end

  it "is idempotent — the same identifier updates instead of duplicating" do
    described_class.new(store: store, attrs: attrs).call
    described_class.new(store: store, attrs: attrs(cost_cny: BigDecimal("100.00"))).call

    expect(Parcel.where(shopify_store: store, identifier: "XMBDE2012381").count).to eq(1)
    expect(Parcel.last.cost_cny).to eq(100)
    expect(order.reload.actual_shipping_cost).to eq(BigDecimal("13.89"))  # 100 / 7.2
  end

  it "leaves order_id nil when the order name matches nothing" do
    parcel = described_class.new(store: store, attrs: attrs(order_name: "PKS#9999")).call

    expect(parcel.order_id).to be_nil
    expect(parcel.cost_amount).to eq(BigDecimal("33.30"))  # still costed — money is never lost
  end

  it "matches the order only within the given store" do
    other_store = create(:shopify_store, user: user, company: user.companies.first, cost_fx_rate: 7.2)
    parcel = described_class.new(store: other_store, attrs: attrs).call

    expect(parcel.order_id).to be_nil
  end

  it "raises MissingFxRate when the store has no cost_fx_rate" do
    store.update!(cost_fx_rate: nil)

    expect { described_class.new(store: store, attrs: attrs).call }
      .to raise_error(ParcelUpserter::MissingFxRate)
  end

  it "raises MissingFxRate when cost_fx_rate is exactly zero" do
    # update_column bypasses the model's `greater_than: 0` validation — a zero rate
    # shouldn't be reachable through normal writes, but the upserter guard is
    # defense-in-depth and must not treat 0 as a truthy, usable rate.
    store.update_column(:cost_fx_rate, 0)

    expect { described_class.new(store: store, attrs: attrs).call }
      .to raise_error(ParcelUpserter::MissingFxRate)
  end

  it "raises MissingCost and persists no parcel when cost_cny is blank" do
    expect {
      expect { described_class.new(store: store, attrs: attrs(cost_cny: nil)).call }
        .to raise_error(ParcelUpserter::MissingCost)
    }.not_to change(Parcel, :count)
  end

  it "handles a resend parcel (R1 suffix) as a separate parcel on the same order" do
    described_class.new(store: store, attrs: attrs(identifier: "XMBDE2012399")).call
    described_class.new(store: store, attrs: attrs(identifier: "XMBDE2012399R1", cost_cny: BigDecimal("65.76"))).call

    expect(order.reload.parcels.count).to eq(2)
    expect(order.actual_shipping_cost).to eq(BigDecimal("42.43"))  # 33.30 + 9.13
  end
end
