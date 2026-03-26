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

    it "#tracking_status returns status" do
      expect(fulfillment.tracking_status).to eq("Delivered")
    end

    it "#last_tracking_event returns last event" do
      expect(fulfillment.last_tracking_event).to eq("Delivered to recipient")
    end

    it "#last_tracking_time returns last event time" do
      expect(fulfillment.last_tracking_time).to eq("2026-03-25 10:00:00")
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
      expect(fulfillment.tracking_status).to be_nil
      expect(fulfillment.last_tracking_event).to be_nil
      expect(fulfillment.tracking_events).to eq([])
      expect(fulfillment.tracking_loaded?).to be false
    end
  end
end
