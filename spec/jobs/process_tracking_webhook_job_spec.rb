require "rails_helper"

RSpec.describe ProcessTrackingWebhookJob, type: :job do
  let(:tracking_service) { instance_double(TrackingService) }
  let(:company) do
    create(:company,
           tracking_enabled: true,
           tracking_api_key: ("A" * 32),
           tracking_mode: "backfill",
           tracking_backfill_days: 30,
           tracking_starts_at: 30.days.ago)
  end

  def fulfillment_for(company, **overrides)
    store = create(:shopify_store, company: company)
    customer = create(:customer, shopify_store: store)
    order = create(:order, customer: customer, shopify_store: store)
    create(:fulfillment, order: order, **overrides)
  end

  before do
    allow(TrackingService).to receive(:new).and_return(tracking_service)
  end

  it "updates fulfillment from webhook payload" do
    fulfillment = fulfillment_for(company, tracking_number: "TRACK1")

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
    fulfillment_for(company, tracking_number: "TRACK1")
    allow(tracking_service).to receive(:track).and_raise(RuntimeError, "API down")

    expect { described_class.perform_now({ "number" => "TRACK1" }) }.not_to raise_error
  end

  it "skips when the owning company has tracking disabled" do
    disabled_company = create(:company)
    fulfillment_for(disabled_company, tracking_number: "NOKEY1")

    expect(TrackingService).not_to receive(:new)

    described_class.perform_now({ "number" => "NOKEY1" })
  end

  it "skips when the owning company has config but is currently disabled" do
    paused = create(:company,
                    tracking_enabled: false,
                    tracking_api_key: "A" * 32,
                    tracking_mode: "new_only",
                    tracking_starts_at: Time.current)
    fulfillment_for(paused, tracking_number: "PAUSED")

    expect(TrackingService).not_to receive(:new)

    described_class.perform_now({ "number" => "PAUSED" })
  end
end
