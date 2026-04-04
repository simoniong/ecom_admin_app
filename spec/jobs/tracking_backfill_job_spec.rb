require "rails_helper"

RSpec.describe TrackingBackfillJob, type: :job do
  let(:tracking_service) { instance_double(TrackingService) }

  before do
    allow(TrackingService).to receive(:new).and_return(tracking_service)
  end

  it "fetches and updates fulfillments with nil tracking_status" do
    fulfillment = create(:fulfillment, tracking_number: "TRACK1", tracking_status: nil)
    result = {
      tracking_number: "TRACK1", status: "InTransit", sub_status: nil,
      last_event: "In transit", last_event_time: "2026-03-24T08:00:00+08:00",
      origin_country: "CN", destination_country: "US",
      origin_carrier: "China Post", destination_carrier: nil,
      transit_days: 3, events: []
    }

    allow(tracking_service).to receive(:register)
    allow(tracking_service).to receive(:track).with([ "TRACK1" ]).and_return([ result ])

    described_class.perform_now

    fulfillment.reload
    expect(fulfillment.tracking_status).to eq("InTransit")
    expect(fulfillment.origin_country).to eq("CN")
  end

  it "skips fulfillments that already have tracking_status" do
    create(:fulfillment, tracking_number: "DONE1", tracking_status: "Delivered")

    expect(TrackingService).not_to receive(:new)
    described_class.perform_now
  end

  it "does nothing when no fulfillments with tracking" do
    expect(TrackingService).not_to receive(:new)
    described_class.perform_now
  end

  it "handles API errors gracefully" do
    create(:fulfillment, tracking_number: "TRACK1", tracking_status: nil)

    allow(tracking_service).to receive(:register)
    allow(tracking_service).to receive(:track).and_raise(RuntimeError, "API down")

    expect { described_class.perform_now }.not_to raise_error
  end

  it "handles per-fulfillment errors without stopping" do
    create(:fulfillment, tracking_number: "TRACK1", tracking_status: nil)

    allow(tracking_service).to receive(:register)
    # Return a result with invalid data that will cause update to fail
    allow(tracking_service).to receive(:track).with([ "TRACK1" ]).and_return([
      { tracking_number: "TRACK1", status: "InTransit", sub_status: nil,
        last_event: "In transit", last_event_time: "invalid-date",
        origin_country: "CN", destination_country: "US",
        origin_carrier: "China Post", destination_carrier: nil,
        transit_days: 3, events: [] }
    ])

    expect { described_class.perform_now }.not_to raise_error
  end
end
