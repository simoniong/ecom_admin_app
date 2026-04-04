require "rails_helper"

RSpec.describe ProcessTrackingWebhookJob, type: :job do
  let(:tracking_service) { instance_double(TrackingService) }

  before do
    allow(TrackingService).to receive(:new).and_return(tracking_service)
  end

  it "updates fulfillment from webhook payload" do
    fulfillment = create(:fulfillment, tracking_number: "TRACK1")

    result = {
      tracking_number: "TRACK1", status: "Delivered", sub_status: nil,
      last_event: "Delivered", last_event_time: "2026-03-25T10:00:00+08:00",
      origin_country: "CN", destination_country: "US",
      origin_carrier: "China Post", destination_carrier: "USPS",
      transit_days: 5, events: []
    }

    allow(tracking_service).to receive(:track).with([ "TRACK1" ]).and_return([ result ])

    described_class.perform_now({ "number" => "TRACK1" })

    fulfillment.reload
    expect(fulfillment.tracking_status).to eq("Delivered")
    expect(fulfillment.destination_country).to eq("US")
  end

  it "handles unknown tracking numbers gracefully" do
    allow(tracking_service).to receive(:track).and_return([])

    expect { described_class.perform_now({ "number" => "UNKNOWN" }) }.not_to raise_error
  end

  it "handles missing number in payload" do
    expect { described_class.perform_now({}) }.not_to raise_error
  end

  it "handles API errors gracefully" do
    create(:fulfillment, tracking_number: "TRACK1")
    allow(tracking_service).to receive(:track).and_raise(RuntimeError, "API down")

    expect { described_class.perform_now({ "number" => "TRACK1" }) }.not_to raise_error
  end
end
