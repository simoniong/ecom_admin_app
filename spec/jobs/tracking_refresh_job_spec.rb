require "rails_helper"

RSpec.describe TrackingRefreshJob, type: :job do
  let(:tracking_service) { instance_double(TrackingService) }

  before do
    allow(TrackingService).to receive(:new).and_return(tracking_service)
  end

  it "updates fulfillments with tracking details via update_from_tracking_result" do
    fulfillment = create(:fulfillment, tracking_number: "TRACK1")
    result = {
      tracking_number: "TRACK1", status: "Delivered", sub_status: nil,
      last_event: "Delivered", last_event_time: "2026-03-25T10:00:00+08:00",
      origin_country: "CN", destination_country: "US",
      origin_carrier: "China Post", destination_carrier: "USPS",
      transit_days: 5, events: []
    }

    allow(tracking_service).to receive(:register).with([ "TRACK1" ])
    allow(tracking_service).to receive(:track).with([ "TRACK1" ]).and_return([ result ])

    described_class.perform_now

    fulfillment.reload
    expect(fulfillment.tracking_status).to eq("Delivered")
    expect(fulfillment.origin_country).to eq("CN")
    expect(fulfillment.destination_country).to eq("US")
  end

  it "only polls non-terminal fulfillments" do
    create(:fulfillment, tracking_number: "ACTIVE1", tracking_status: "InTransit")
    create(:fulfillment, tracking_number: "DONE1", tracking_status: "Delivered")
    create(:fulfillment, tracking_number: "EXPIRED1", tracking_status: "Expired")

    allow(tracking_service).to receive(:register)
    allow(tracking_service).to receive(:track).and_return([])

    described_class.perform_now

    expect(tracking_service).to have_received(:track).with([ "ACTIVE1" ])
  end

  it "registers unregistered tracking numbers before fetching" do
    create(:fulfillment, tracking_number: "NEW1", tracking_details: {})
    create(:fulfillment, tracking_number: "OLD1", tracking_details: { "status" => "InTransit" }, tracking_status: "InTransit")

    allow(tracking_service).to receive(:register).with([ "NEW1" ])
    allow(tracking_service).to receive(:track).and_return([])

    described_class.perform_now

    expect(tracking_service).to have_received(:register).with([ "NEW1" ])
  end

  it "batches tracking numbers in groups of 40" do
    45.times { |i| create(:fulfillment, tracking_number: "TRACK#{i}") }

    allow(tracking_service).to receive(:register)
    allow(tracking_service).to receive(:track).and_return([])

    described_class.perform_now

    expect(tracking_service).to have_received(:track).twice
  end

  it "does nothing when no fulfillments with tracking" do
    create(:fulfillment, tracking_number: nil)

    expect(TrackingService).not_to receive(:new)

    described_class.perform_now
  end

  it "handles API errors gracefully" do
    create(:fulfillment, tracking_number: "TRACK1")

    allow(tracking_service).to receive(:register)
    allow(tracking_service).to receive(:track).and_raise(RuntimeError, "API down")

    expect { described_class.perform_now }.not_to raise_error
  end
end
