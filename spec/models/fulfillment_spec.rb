require "rails_helper"

RSpec.describe Fulfillment, type: :model do
  it "is valid with valid attributes" do
    fulfillment = build(:fulfillment)
    expect(fulfillment).to be_valid
  end

  it "requires shopify_fulfillment_id" do
    fulfillment = build(:fulfillment, shopify_fulfillment_id: nil)
    expect(fulfillment).not_to be_valid
  end

  it "enforces shopify_fulfillment_id uniqueness" do
    create(:fulfillment, shopify_fulfillment_id: 77777)
    duplicate = build(:fulfillment, shopify_fulfillment_id: 77777)
    expect(duplicate).not_to be_valid
  end

  it "belongs to order" do
    fulfillment = create(:fulfillment)
    expect(fulfillment.order).to be_a(Order)
  end

  describe ".with_tracking" do
    it "returns fulfillments with tracking numbers" do
      with = create(:fulfillment, tracking_number: "TRACK123")
      create(:fulfillment, tracking_number: nil)
      create(:fulfillment, tracking_number: "")
      expect(Fulfillment.with_tracking).to eq([ with ])
    end
  end

  describe ".non_terminal" do
    it "excludes Delivered and Expired fulfillments" do
      in_transit = create(:fulfillment, tracking_status: "InTransit")
      create(:fulfillment, tracking_status: "Delivered")
      create(:fulfillment, tracking_status: "Expired")
      pending_f = create(:fulfillment, tracking_status: nil)

      result = Fulfillment.non_terminal
      expect(result).to include(in_transit, pending_f)
      expect(result.count).to eq(2)
    end
  end

  describe ".by_tracking_status" do
    it "filters by tracking status" do
      delivered = create(:fulfillment, tracking_status: "Delivered")
      create(:fulfillment, tracking_status: "InTransit")

      expect(Fulfillment.by_tracking_status("Delivered")).to eq([ delivered ])
    end
  end

  describe ".by_destination" do
    it "filters by destination country" do
      us = create(:fulfillment, destination_country: "US")
      create(:fulfillment, destination_country: "AU")

      expect(Fulfillment.by_destination("US")).to eq([ us ])
    end
  end

  describe ".by_origin_carrier" do
    it "filters by origin carrier" do
      cp = create(:fulfillment, origin_carrier: "China Post")
      create(:fulfillment, origin_carrier: "DHL")

      expect(Fulfillment.by_origin_carrier("China Post")).to eq([ cp ])
    end
  end

  describe ".by_destination_carrier" do
    it "filters by destination carrier" do
      usps = create(:fulfillment, destination_carrier: "USPS")
      create(:fulfillment, destination_carrier: "FedEx")

      expect(Fulfillment.by_destination_carrier("USPS")).to eq([ usps ])
    end
  end

  describe ".by_store" do
    it "filters by shopify store" do
      store = create(:shopify_store)
      other_store = create(:shopify_store)
      order1 = create(:order, shopify_store: store)
      order2 = create(:order, shopify_store: other_store)
      f1 = create(:fulfillment, order: order1)
      create(:fulfillment, order: order2)

      expect(Fulfillment.by_store(store.id)).to eq([ f1 ])
    end
  end

  describe ".search_by" do
    it "searches by tracking number" do
      f = create(:fulfillment, tracking_number: "DOR019055CN")
      create(:fulfillment, tracking_number: "OTHER123")

      expect(Fulfillment.search_by("DOR019")).to eq([ f ])
    end

    it "searches by order name" do
      order = create(:order, name: "PKS#2431")
      f = create(:fulfillment, order: order)
      create(:fulfillment)

      expect(Fulfillment.search_by("PKS#2431")).to eq([ f ])
    end

    it "searches by customer email" do
      customer = create(:customer, email: "john@example.com")
      order = create(:order, customer: customer)
      f = create(:fulfillment, order: order)
      create(:fulfillment)

      expect(Fulfillment.search_by("john@example")).to eq([ f ])
    end
  end

  describe ".by_shipped_between" do
    it "filters by shipped_at range" do
      f1 = create(:fulfillment, shipped_at: 2.days.ago)
      create(:fulfillment, shipped_at: 10.days.ago)

      expect(Fulfillment.by_shipped_between(3.days.ago, Time.current)).to eq([ f1 ])
    end
  end

  describe ".by_ordered_between" do
    it "filters by order's ordered_at range" do
      order1 = create(:order, ordered_at: 2.days.ago)
      order2 = create(:order, ordered_at: 10.days.ago)
      f1 = create(:fulfillment, order: order1)
      create(:fulfillment, order: order2)

      expect(Fulfillment.by_ordered_between(3.days.ago, Time.current)).to eq([ f1 ])
    end
  end

  describe "#status_badge_classes" do
    it "returns correct classes for known statuses" do
      fulfillment = build(:fulfillment, tracking_status: "Delivered")
      expect(fulfillment.status_badge_classes).to eq("bg-green-100 text-green-800")
    end

    it "returns default for unknown status" do
      fulfillment = build(:fulfillment, tracking_status: "Unknown")
      expect(fulfillment.status_badge_classes).to eq("bg-gray-100 text-gray-600")
    end
  end

  describe "#tracking_status_display" do
    it "maps Exception to Alert" do
      fulfillment = build(:fulfillment, tracking_status: "Exception")
      expect(fulfillment.tracking_status_display).to eq("Alert")
    end

    it "maps AvailableForPickup to Pick Up" do
      fulfillment = build(:fulfillment, tracking_status: "AvailableForPickup")
      expect(fulfillment.tracking_status_display).to eq("Pick Up")
    end

    it "maps DeliveryFailure to Undelivered" do
      fulfillment = build(:fulfillment, tracking_status: "DeliveryFailure")
      expect(fulfillment.tracking_status_display).to eq("Undelivered")
    end

    it "uses display name for known statuses" do
      fulfillment = build(:fulfillment, tracking_status: "InfoReceived")
      expect(fulfillment.tracking_status_display).to eq("Info Received")
    end

    it "falls back to camelCase splitting for unknown statuses" do
      fulfillment = build(:fulfillment, tracking_status: "SomeNewStatus")
      expect(fulfillment.tracking_status_display).to eq("Some New Status")
    end

    it "handles single-word statuses" do
      fulfillment = build(:fulfillment, tracking_status: "Delivered")
      expect(fulfillment.tracking_status_display).to eq("Delivered")
    end
  end

  describe "#shopify_shipped_at" do
    it "parses created_at from shopify_data" do
      fulfillment = build(:fulfillment, shopify_data: { "created_at" => "2026-04-01T08:00:00-07:00" })
      expect(fulfillment.shopify_shipped_at).to be_a(ActiveSupport::TimeWithZone)
    end

    it "returns nil when shopify_data has no created_at" do
      fulfillment = build(:fulfillment, shopify_data: {})
      expect(fulfillment.shopify_shipped_at).to be_nil
    end

    it "returns nil when shopify_data is nil" do
      fulfillment = build(:fulfillment, shopify_data: nil)
      expect(fulfillment.shopify_shipped_at).to be_nil
    end

    it "returns nil for unparseable timestamps" do
      fulfillment = build(:fulfillment, shopify_data: { "created_at" => "not-a-date" })
      expect(fulfillment.shopify_shipped_at).to be_nil
    end
  end

  describe "#update_from_tracking_result" do
    let(:fulfillment) { create(:fulfillment, tracking_number: "TRACK123") }
    let(:result) do
      {
        tracking_number: "TRACK123",
        status: "InTransit",
        sub_status: "InTransit_Collected",
        last_event: "Package collected",
        last_event_time: "2026-03-24T08:00:00+08:00",
        origin_country: "CN",
        destination_country: "US",
        origin_carrier: "China Post",
        destination_carrier: "USPS",
        transit_days: 3,
        events: [
          { description: "Package collected", time: "2026-03-24T08:00:00+08:00", location: "Shanghai" }
        ]
      }
    end

    it "updates all tracking fields from result hash" do
      fulfillment.update_from_tracking_result(result)
      fulfillment.reload

      expect(fulfillment.tracking_status).to eq("InTransit")
      expect(fulfillment.tracking_sub_status).to eq("InTransit_Collected")
      expect(fulfillment.origin_country).to eq("CN")
      expect(fulfillment.destination_country).to eq("US")
      expect(fulfillment.origin_carrier).to eq("China Post")
      expect(fulfillment.destination_carrier).to eq("USPS")
      expect(fulfillment.transit_days).to eq(3)
      expect(fulfillment.latest_event_description).to eq("Package collected")
      expect(fulfillment.last_event_at).to be_present
      expect(fulfillment.tracking_details).to be_present
    end

    it "extracts shipped_at from first transit event" do
      fulfillment.update_from_tracking_result(result)
      expect(fulfillment.shipped_at).to be_present
    end

    it "extracts delivered_at when status is Delivered" do
      delivered_result = result.merge(status: "Delivered")
      fulfillment.update_from_tracking_result(delivered_result)
      expect(fulfillment.delivered_at).to be_present
    end

    it "does not set delivered_at for non-Delivered status" do
      fulfillment.update_from_tracking_result(result)
      expect(fulfillment.delivered_at).to be_nil
    end
  end

  describe "tracking helpers" do
    let(:fulfillment) do
      build(:fulfillment, tracking_details: {
        "status" => "Delivered",
        "last_event" => "Delivered to recipient",
        "last_event_time" => "2026-03-25 10:00:00",
        "events" => [
          { "description" => "Shipped", "time" => "2026-03-20 08:00", "location" => "LA" },
          { "description" => "Delivered", "time" => "2026-03-25 10:00", "location" => "NYC" }
        ]
      })
    end

    it "#tracking_events returns events in reverse chronological order" do
      events = fulfillment.tracking_events
      expect(events.first["description"]).to eq("Delivered")
      expect(events.last["description"]).to eq("Shipped")
    end

    it "#tracking_loaded? returns true when details present" do
      expect(fulfillment.tracking_loaded?).to be true
    end

    it "#tracking_loaded? returns false when details empty" do
      fulfillment.tracking_details = {}
      expect(fulfillment.tracking_loaded?).to be false
    end

    it "handles nil tracking_details gracefully" do
      fulfillment.tracking_details = nil
      expect(fulfillment.tracking_events).to eq([])
      expect(fulfillment.tracking_loaded?).to be false
    end
  end

  describe "after_commit :register_tracking" do
    def enable_tracking_on(company, mode: "backfill", days: 30)
      effective_days = mode == "backfill" ? days : nil
      company.update!(
        tracking_enabled: true,
        tracking_api_key: "A" * 32,
        tracking_mode: mode,
        tracking_backfill_days: effective_days,
        tracking_starts_at: Company.starts_at_for(mode: mode, days: effective_days)
      )
    end

    it "enqueues TrackingRegisterJob when tracking is enabled and the order is within window" do
      fulfillment = create(:fulfillment, tracking_number: nil)
      company = fulfillment.order.shopify_store.company
      enable_tracking_on(company)

      expect {
        fulfillment.update!(tracking_number: "NEW123")
      }.to have_enqueued_job(TrackingRegisterJob).with(company.id, [ "NEW123" ])
    end

    it "does not enqueue when the owning company has not enabled tracking" do
      fulfillment = create(:fulfillment, tracking_number: nil)

      expect {
        fulfillment.update!(tracking_number: "NEW123")
      }.not_to have_enqueued_job(TrackingRegisterJob)
    end

    it "does not enqueue when the order is older than tracking_starts_at" do
      fulfillment = create(:fulfillment, tracking_number: nil)
      company = fulfillment.order.shopify_store.company
      enable_tracking_on(company, mode: "new_only")
      fulfillment.order.update!(ordered_at: 1.day.ago)

      expect {
        fulfillment.update!(tracking_number: "OLD123")
      }.not_to have_enqueued_job(TrackingRegisterJob)
    end

    it "does not enqueue when tracking_number is unchanged" do
      fulfillment = create(:fulfillment, tracking_number: "EXISTING")

      expect {
        fulfillment.update!(status: "delivered")
      }.not_to have_enqueued_job(TrackingRegisterJob)
    end

    it "does not enqueue when tracking_number is cleared" do
      fulfillment = create(:fulfillment, tracking_number: "EXISTING")

      expect {
        fulfillment.update!(tracking_number: nil)
      }.not_to have_enqueued_job(TrackingRegisterJob)
    end
  end
end
