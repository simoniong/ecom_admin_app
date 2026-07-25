require "rails_helper"

RSpec.describe PackageListQuery do
  let(:store)    { create(:shopify_store) }
  let(:customer) { create(:customer, shopify_store: store) }
  let(:scope)    { Package.where(shopify_store_id: store.id, aasm_state: "pending_review") }

  # snapshot_country: 寫進 package 的地址快照（列表優先取這個）
  # shopify_country:  寫進訂單的 Shopify 原始地址（快照缺值時的退路）
  def make_package(number:, snapshot_country: nil, shopify_country: nil,
                   ordered_at: 1.day.ago, paid_at: 1.day.ago, created_at: 1.day.ago)
    shopify_data = shopify_country ? { "shipping_address" => { "country_code" => shopify_country } } : {}
    order = create(:order, customer: customer, shopify_store: store,
                   ordered_at: ordered_at, paid_at: paid_at, shopify_data: shopify_data)
    snapshot = snapshot_country ? { "country_code" => snapshot_country } : {}
    create(:package, shopify_store: store, order: order, number: number,
           created_at: created_at, shipping_address_snapshot: snapshot)
  end

  describe "#countries" do
    it "returns the distinct country codes present in the scope" do
      make_package(number: 1, snapshot_country: "US")
      make_package(number: 2, snapshot_country: "US")
      make_package(number: 3, snapshot_country: "CA")

      expect(described_class.new(scope).countries).to match_array(%w[US CA])
    end

    it "falls back to the order's Shopify address when the snapshot has no country" do
      make_package(number: 1, shopify_country: "DE")

      expect(described_class.new(scope).countries).to eq([ "DE" ])
    end

    it "ignores packages with no country anywhere" do
      make_package(number: 1, snapshot_country: "US")
      make_package(number: 2)

      expect(described_class.new(scope).countries).to eq([ "US" ])
    end

    it "treats a whitespace-only snapshot country as absent and falls back" do
      make_package(number: 1, snapshot_country: "   ", shopify_country: "GB")

      expect(described_class.new(scope).countries).to eq([ "GB" ])
    end

    it "normalizes case so a hand-edited lowercase code is not a separate bucket" do
      make_package(number: 1, snapshot_country: "US")
      make_package(number: 2, snapshot_country: "us")

      expect(described_class.new(scope).countries).to eq([ "US" ])
    end
  end

  describe "#country" do
    it "accepts a country present in the scope" do
      make_package(number: 1, snapshot_country: "US")

      expect(described_class.new(scope, country: "US").country).to eq("US")
    end

    it "upcases the incoming value" do
      make_package(number: 1, snapshot_country: "US")

      expect(described_class.new(scope, country: "us").country).to eq("US")
    end

    it "ignores a country that is not in the scope" do
      make_package(number: 1, snapshot_country: "US")

      expect(described_class.new(scope, country: "CA").country).to be_nil
    end

    it "ignores a blank country" do
      make_package(number: 1, snapshot_country: "US")

      expect(described_class.new(scope, country: "").country).to be_nil
    end
  end

  describe "#relation country filtering" do
    it "keeps only packages matching the country" do
      us = make_package(number: 1, snapshot_country: "US")
      make_package(number: 2, snapshot_country: "CA")

      expect(described_class.new(scope, country: "US").relation).to eq([ us ])
    end

    it "matches on the order's Shopify address when the snapshot has no country" do
      de = make_package(number: 1, shopify_country: "DE")
      make_package(number: 2, snapshot_country: "US")

      expect(described_class.new(scope, country: "DE").relation).to eq([ de ])
    end

    it "matches a hand-edited lowercase country code" do
      lower = make_package(number: 1, snapshot_country: "us")
      make_package(number: 2, snapshot_country: "CA")

      expect(described_class.new(scope, country: "US").relation).to eq([ lower ])
    end

    it "returns everything when the country is not in the scope" do
      make_package(number: 1, snapshot_country: "US")
      make_package(number: 2, snapshot_country: "CA")

      expect(described_class.new(scope, country: "JP").relation.count).to eq(2)
    end
  end

  describe "#relation sorting" do
    it "defaults to newest package first" do
      old = make_package(number: 1, created_at: 3.days.ago)
      new = make_package(number: 2, created_at: 1.hour.ago)

      expect(described_class.new(scope).relation).to eq([ new, old ])
    end

    it "sorts by the order's ordered_at ascending" do
      late  = make_package(number: 1, ordered_at: 1.hour.ago)
      early = make_package(number: 2, ordered_at: 5.days.ago)

      result = described_class.new(scope, sort_column: "ordered_at", sort_direction: "asc").relation
      expect(result).to eq([ early, late ])
    end

    it "sorts by the order's paid_at descending" do
      early = make_package(number: 1, paid_at: 5.days.ago)
      late  = make_package(number: 2, paid_at: 1.hour.ago)

      result = described_class.new(scope, sort_column: "paid_at", sort_direction: "desc").relation
      expect(result).to eq([ late, early ])
    end

    it "puts records with no paid_at last even when sorting ascending" do
      paid   = make_package(number: 1, paid_at: 5.days.ago)
      unpaid = make_package(number: 2, paid_at: nil)

      result = described_class.new(scope, sort_column: "paid_at", sort_direction: "asc").relation
      expect(result).to eq([ paid, unpaid ])
    end

    it "breaks ties on id so pagination stays stable" do
      at = 2.days.ago
      make_package(number: 1, created_at: at)
      make_package(number: 2, created_at: at)

      first_run  = described_class.new(scope).relation.pluck(:id)
      second_run = described_class.new(scope).relation.pluck(:id)
      expect(first_run).to eq(second_run)
      expect(first_run.uniq.size).to eq(2)
    end

    it "falls back to the default column for an unknown sort_column" do
      query = described_class.new(scope, sort_column: "drop table")
      expect(query.sort_column).to eq("created_at")
    end

    it "falls back to desc for an unknown sort_direction" do
      query = described_class.new(scope, sort_direction: "sideways")
      expect(query.sort_direction).to eq("desc")
    end

    it "accepts asc as a sort_direction" do
      query = described_class.new(scope, sort_direction: "asc")
      expect(query.sort_direction).to eq("asc")
    end
  end
end
