require "rails_helper"

RSpec.describe TrackingRegisterJob, type: :job do
  let(:company) do
    create(:company,
           tracking_enabled: true,
           tracking_api_key: ("A" * 32),
           tracking_mode: "new_only",
           tracking_starts_at: Time.current)
  end

  it "registers tracking numbers via TrackingService with the company's api key" do
    tracking_service = instance_double(TrackingService)
    allow(TrackingService).to receive(:new).with(api_key: ("A" * 32)).and_return(tracking_service)
    allow(tracking_service).to receive(:register).with([ "TRACK1" ]).and_return([ { "number" => "TRACK1" } ])

    described_class.perform_now(company.id, [ "TRACK1" ])

    expect(tracking_service).to have_received(:register).with([ "TRACK1" ])
  end

  it "does nothing for blank input" do
    expect(TrackingService).not_to receive(:new)

    described_class.perform_now(company.id, [])
  end

  it "does nothing when company has tracking disabled" do
    disabled_company = create(:company)

    expect(TrackingService).not_to receive(:new)

    described_class.perform_now(disabled_company.id, [ "TRACK1" ])
  end

  it "does nothing when company has config but tracking is currently disabled" do
    paused = create(:company,
                    tracking_enabled: false,
                    tracking_api_key: "A" * 32,
                    tracking_mode: "new_only",
                    tracking_starts_at: Time.current)

    expect(TrackingService).not_to receive(:new)

    described_class.perform_now(paused.id, [ "TRACK1" ])
  end

  it "does nothing when company is missing" do
    expect(TrackingService).not_to receive(:new)

    described_class.perform_now(SecureRandom.uuid, [ "TRACK1" ])
  end

  it "retries on failure" do
    tracking_service = instance_double(TrackingService)
    allow(TrackingService).to receive(:new).and_return(tracking_service)
    allow(tracking_service).to receive(:register).and_raise(StandardError, "API down")

    expect {
      described_class.perform_now(company.id, [ "TRACK1" ])
    }.to have_enqueued_job(TrackingRegisterJob).with(company.id, [ "TRACK1" ])
  end
end
