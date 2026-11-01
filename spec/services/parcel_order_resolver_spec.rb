require "rails_helper"

RSpec.describe ParcelOrderResolver do
  let(:store) { create(:shopify_store, package_prefix: "XMBDP") }
  let(:order) { create(:order, shopify_store: store, name: "PKS#4001") }

  def row(**attrs)
    { identifier: attrs[:package_code], order_name: nil, internal_no: nil, tracking_number: nil }.merge(attrs)
  end

  describe "by Shopify fulfillment tracking number" do
    it "matches the waybill (运单号) the ERP wrote back to Shopify" do
      create(:fulfillment, order: order, tracking_number: "DOR0229399275CN")

      result = described_class.new(store).call([
        row(package_code: "XMBDP1004342", internal_no: "DOR0229399275CN", tracking_number: "YWE1")
      ])

      expect(result.first[:order_name]).to eq("PKS#4001")
    end

    it "matches the last-mile number when that is what Shopify holds" do
      create(:fulfillment, order: order, tracking_number: "YWE00001676211752")

      result = described_class.new(store).call([
        row(package_code: "XMBDP1", internal_no: "DOR-X", tracking_number: "YWE00001676211752")
      ])

      expect(result.first[:order_name]).to eq("PKS#4001")
    end

    it "works when the store has no package prefix and no packages at all" do
      store.update_columns(package_prefix: nil)
      create(:fulfillment, order: order, tracking_number: "DOR1")

      result = described_class.new(store).call([ row(package_code: "XMBDP1004013R1", internal_no: "DOR1") ])

      expect(result.first[:order_name]).to eq("PKS#4001")
    end

    it "never matches another store's fulfillment" do
      other_order = create(:order, shopify_store: create(:shopify_store), name: "OTHER#1")
      create(:fulfillment, order: other_order, tracking_number: "DOR1")

      result = described_class.new(store).call([ row(package_code: "XMBDP1", internal_no: "DOR1") ])

      expect(result.first[:order_name]).to be_nil
    end

    it "prefers the fulfillment match over a package match" do
      create(:fulfillment, order: order, tracking_number: "DOR1")
      other = create(:order, shopify_store: store, name: "PKS#4002")
      create(:package, shopify_store: store, order: other, number: 1_004_342)

      result = described_class.new(store).call([ row(package_code: "XMBDP1004342", internal_no: "DOR1") ])

      expect(result.first[:order_name]).to eq("PKS#4001")
    end
  end

  it "resolves the order from the package code" do
    create(:package, shopify_store: store, order: order, number: 1_004_342)

    result = described_class.new(store).call([ row(package_code: "XMBDP1004342") ])

    expect(result.first[:order_name]).to eq("PKS#4001")
  end

  it "matches a zero-padded package code" do
    create(:package, shopify_store: store, order: order, number: 42)

    result = described_class.new(store).call([ row(package_code: "XMBDP0000042") ])

    expect(result.first[:order_name]).to eq("PKS#4001")
  end

  it "falls back to the package's tracking number when the prefix is not the store's" do
    create(:package, shopify_store: store, order: order, number: 7, tracking_number: "DOR0229399275CN")

    result = described_class.new(store).call([
      row(package_code: "XMBDE0000007", internal_no: "DOR0229399275CN")
    ])

    expect(result.first[:order_name]).to eq("PKS#4001")
  end

  it "falls back to the last-mile tracking number too" do
    create(:package, shopify_store: store, order: order, number: 8, tracking_number: "YWE00001676211752")

    result = described_class.new(store).call([
      row(package_code: "OTHER1", internal_no: "DOR-X", tracking_number: "YWE00001676211752")
    ])

    expect(result.first[:order_name]).to eq("PKS#4001")
  end

  it "never matches another store's package with the same number" do
    other_store = create(:shopify_store, package_prefix: "XMBDP")
    create(:package, shopify_store: other_store, number: 1_004_342)

    result = described_class.new(store).call([ row(package_code: "XMBDP1004342") ])

    expect(result.first[:order_name]).to be_nil
  end

  it "leaves the row unmatched when nothing fits" do
    result = described_class.new(store).call([ row(package_code: "XMBDP9999999", internal_no: "DOR-NONE") ])

    expect(result.first[:order_name]).to be_nil
  end

  it "ignores a code whose remainder after the prefix is not numeric" do
    create(:package, shopify_store: store, order: order, number: 12)

    result = described_class.new(store).call([ row(package_code: "XMBDP12A") ])

    expect(result.first[:order_name]).to be_nil
  end

  it "does nothing when the store has no package prefix" do
    store.update_columns(package_prefix: nil)
    create(:package, shopify_store: store, order: order, number: 5)

    result = described_class.new(store).call([ row(package_code: "XMBDP0000005") ])

    expect(result.first[:order_name]).to be_nil
  end

  it "passes rows that already carry an order name, or no package code, through untouched" do
    dianxiaomi = { identifier: "XMBDE1", order_name: "PKS#3037" }
    no_code = { identifier: "X2", order_name: nil }

    result = described_class.new(store).call([ dianxiaomi, no_code ])

    expect(result).to eq([ dianxiaomi, no_code ])
  end
end
