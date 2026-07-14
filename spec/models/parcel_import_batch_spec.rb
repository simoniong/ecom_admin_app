require "rails_helper"

RSpec.describe ParcelImportBatch, type: :model do
  let(:user)    { create(:user) }
  let(:company) { user.companies.first }
  let(:store)   { create(:shopify_store, user: user, company: company, cost_fx_rate: 7.2) }

  describe "validations" do
    it "is valid with the factory defaults" do
      expect(build(:parcel_import_batch, shopify_store: store, user: user)).to be_valid
    end

    it "requires status to be one of the known values" do
      batch = build(:parcel_import_batch, shopify_store: store, user: user, status: "bogus")

      expect(batch).not_to be_valid
      expect(batch.errors[:status]).to be_present
    end

    it "requires a non-negative row_count" do
      batch = build(:parcel_import_batch, shopify_store: store, user: user, row_count: -1)

      expect(batch).not_to be_valid
      expect(batch.errors[:row_count]).to be_present
    end

    it "requires a shopify_store" do
      expect(build(:parcel_import_batch, shopify_store: nil, user: user)).not_to be_valid
    end

    it "requires a user" do
      expect(build(:parcel_import_batch, shopify_store: store, user: nil)).not_to be_valid
    end
  end

  describe "#pending? / #completed?" do
    it "reports pending for a freshly staged batch" do
      batch = create(:parcel_import_batch, shopify_store: store, user: user, status: "pending")

      expect(batch).to be_pending
      expect(batch).not_to be_completed
    end

    it "reports completed once confirmed" do
      batch = create(:parcel_import_batch, shopify_store: store, user: user, status: "completed", completed_at: Time.current)

      expect(batch).to be_completed
      expect(batch).not_to be_pending
    end
  end

  describe ".pending scope" do
    it "returns only pending batches, excluding completed ones" do
      pending_batch   = create(:parcel_import_batch, shopify_store: store, user: user, status: "pending")
      completed_batch = create(:parcel_import_batch, shopify_store: store, user: user, status: "completed", completed_at: Time.current)

      expect(ParcelImportBatch.pending).to contain_exactly(pending_batch)
      expect(ParcelImportBatch.pending).not_to include(completed_batch)
    end
  end

  describe "jsonb rows round trip" do
    it "stores rows as JSON scalars — money/timestamps come back as strings, not their original Ruby types" do
      shipped_at = Time.zone.parse("2026-06-01 21:48:26")
      batch = create(:parcel_import_batch,
        shopify_store: store, user: user,
        rows: [ { identifier: "XMBDE2012381", cost_cny: BigDecimal("239.73"), shipped_at: shipped_at } ]
      )

      reloaded_row = ParcelImportBatch.find(batch.id).rows.first

      expect(reloaded_row.keys).to all(be_a(String))
      expect(reloaded_row["cost_cny"]).to eq("239.73")
      expect(reloaded_row["cost_cny"]).to be_a(String)
      expect(Time.zone.parse(reloaded_row["shipped_at"])).to be_within(1.second).of(shipped_at)
    end
  end

  # staged_rows is what makes the jsonb round trip above safe to compute on:
  # the preview totals and the confirm-time upsert both read money back out of
  # this column, and summing JSON strings would either raise or concatenate.
  describe "#staged_rows" do
    let(:batch) do
      create(:parcel_import_batch, shopify_store: store, user: user, rows: [
        { identifier: "XMBDE2012381", order_name: "PKS#3037", cost_cny: BigDecimal("239.73") },
        { identifier: "XMBDE2012382", order_name: "PKS#3038", cost_cny: BigDecimal("65.57") }
      ])
    end

    it "symbolizes keys and rehydrates money into BigDecimal, never Float" do
      rows = ParcelImportBatch.find(batch.id).staged_rows

      expect(rows.first[:identifier]).to eq("XMBDE2012381")
      expect(rows.first[:cost_cny]).to be_a(BigDecimal)
      expect(rows.first[:cost_cny]).to eq(BigDecimal("239.73"))
    end

    it "produces rows that can be summed exactly" do
      total = ParcelImportBatch.find(batch.id).staged_rows.sum { |r| r[:cost_cny] }

      expect(total).to eq(BigDecimal("305.30"))
    end

    it "leaves a row with no cost_cny alone rather than coercing it to zero" do
      batch = create(:parcel_import_batch, shopify_store: store, user: user,
                     rows: [ { identifier: "XMBDE2012381", cost_cny: nil } ])

      expect(ParcelImportBatch.find(batch.id).staged_rows.first[:cost_cny]).to be_nil
    end
  end
end
