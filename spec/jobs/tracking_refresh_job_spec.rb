require "rails_helper"

RSpec.describe TrackingRefreshJob, type: :job do
  it "updates fulfillments with tracking details" do
    fulfillment = create(:fulfillment, tracking_number: "TRACK1")

    tracking_service = instance_double(TrackingService)
    allow(TrackingService).to receive(:new).and_return(tracking_service)
    allow(tracking_service).to receive(:register).with([ "TRACK1" ])
    allow(tracking_service).to receive(:track).with([ "TRACK1" ]).and_return([
      { tracking_number: "TRACK1", status: "Delivered", last_event: "Delivered", events: [] }
    ])

    described_class.perform_now

    fulfillment.reload
    expect(fulfillment.tracking_details["status"]).to eq("Delivered")
  end

  it "registers unregistered tracking numbers before fetching" do
    create(:fulfillment, tracking_number: "NEW1", tracking_details: {})
    create(:fulfillment, tracking_number: "OLD1", tracking_details: { "status" => "InTransit" })

    tracking_service = instance_double(TrackingService)
    allow(TrackingService).to receive(:new).and_return(tracking_service)
    allow(tracking_service).to receive(:register).with([ "NEW1" ])
    allow(tracking_service).to receive(:track).and_return([])

    described_class.perform_now

    expect(tracking_service).to have_received(:register).with([ "NEW1" ])
  end

  it "does nothing when no fulfillments with tracking" do
    create(:fulfillment, tracking_number: nil)

    expect(TrackingService).not_to receive(:new)

    described_class.perform_now
  end

  it "handles API errors gracefully" do
    create(:fulfillment, tracking_number: "TRACK1")

    tracking_service = instance_double(TrackingService)
    allow(TrackingService).to receive(:new).and_return(tracking_service)
    allow(tracking_service).to receive(:register)
    allow(tracking_service).to receive(:track).and_raise(RuntimeError, "API down")

    expect { described_class.perform_now }.not_to raise_error
  end
end
