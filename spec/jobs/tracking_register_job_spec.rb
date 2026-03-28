require "rails_helper"

RSpec.describe TrackingRegisterJob, type: :job do
  it "registers tracking numbers via TrackingService" do
    tracking_service = instance_double(TrackingService)
    allow(TrackingService).to receive(:new).and_return(tracking_service)
    allow(tracking_service).to receive(:register).with([ "TRACK1" ]).and_return([ { "number" => "TRACK1" } ])

    described_class.perform_now([ "TRACK1" ])

    expect(tracking_service).to have_received(:register).with([ "TRACK1" ])
  end

  it "does nothing for blank input" do
    expect(TrackingService).not_to receive(:new)

    described_class.perform_now([])
  end

  it "retries on failure" do
    tracking_service = instance_double(TrackingService)
    allow(TrackingService).to receive(:new).and_return(tracking_service)
    allow(tracking_service).to receive(:register).and_raise(StandardError, "API down")

    expect {
      described_class.perform_now([ "TRACK1" ])
    }.to have_enqueued_job(TrackingRegisterJob).with([ "TRACK1" ])
  end
end
