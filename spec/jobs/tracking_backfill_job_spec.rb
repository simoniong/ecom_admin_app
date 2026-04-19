require "rails_helper"

RSpec.describe TrackingBackfillJob, type: :job do
  let(:tracking_service) { instance_double(TrackingService) }

  def fulfillment_for(company, ordered_at: 1.day.ago, **overrides)
    store = create(:shopify_store, company: company)
    customer = create(:customer, shopify_store: store)
    order = create(:order, customer: customer, shopify_store: store, ordered_at: ordered_at)
    create(:fulfillment, order: order, **overrides)
  end

  def enable_tracking(company, key:, mode: "backfill", days: 30)
    effective_days = mode == "backfill" ? days : nil
    company.update!(
      tracking_enabled: true,
      tracking_api_key: key,
      tracking_mode: mode,
      tracking_backfill_days: effective_days,
      tracking_starts_at: Company.starts_at_for(mode: mode, days: effective_days)
    )
  end

  before do
    allow(TrackingService).to receive(:new).and_return(tracking_service)
  end

  it "fetches and updates fulfillments with nil tracking_status" do
    company = create(:company)
    enable_tracking(company, key: ("A" * 32))
    fulfillment = fulfillment_for(company, tracking_number: "TRACK1", tracking_status: nil)
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
    company = create(:company)
    enable_tracking(company, key: ("A" * 32))
    fulfillment_for(company, tracking_number: "DONE1", tracking_status: "Delivered")

    expect(TrackingService).not_to receive(:new)
    described_class.perform_now
  end

  it "does nothing when no fulfillments with tracking" do
    expect(TrackingService).not_to receive(:new)
    described_class.perform_now
  end

  it "skips companies that have tracking disabled" do
    company = create(:company)
    fulfillment_for(company, tracking_number: "TRACK1", tracking_status: nil)

    expect(TrackingService).not_to receive(:new)
    described_class.perform_now
  end

  it "skips companies whose config exists but are currently disabled" do
    company = create(:company,
                     tracking_enabled: false,
                     tracking_api_key: "A" * 32,
                     tracking_mode: "backfill",
                     tracking_backfill_days: 30,
                     tracking_starts_at: 30.days.ago)
    fulfillment_for(company, tracking_number: "TRACK1", tracking_status: nil)

    expect(TrackingService).not_to receive(:new)
    described_class.perform_now
  end

  it "excludes orders outside the tracking_starts_at window in new_only mode" do
    company = create(:company)
    starts_at = 1.hour.ago
    company.update!(tracking_enabled: true, tracking_api_key: ("A" * 32), tracking_mode: "new_only", tracking_starts_at: starts_at)
    fulfillment_for(company, ordered_at: starts_at + 10.minutes, tracking_number: "AFTER", tracking_status: nil)
    fulfillment_for(company, ordered_at: starts_at - 10.minutes, tracking_number: "BEFORE", tracking_status: nil)

    allow(tracking_service).to receive(:register)
    allow(tracking_service).to receive(:track).and_return([])

    described_class.perform_now

    expect(tracking_service).to have_received(:track).with([ "AFTER" ])
  end

  it "handles API errors gracefully" do
    company = create(:company)
    enable_tracking(company, key: ("A" * 32))
    fulfillment_for(company, tracking_number: "TRACK1", tracking_status: nil)

    allow(tracking_service).to receive(:register)
    allow(tracking_service).to receive(:track).and_raise(RuntimeError, "API down")

    expect { described_class.perform_now }.not_to raise_error
  end

  it "handles per-fulfillment errors without stopping" do
    company = create(:company)
    enable_tracking(company, key: ("A" * 32))
    fulfillment_for(company, tracking_number: "TRACK1", tracking_status: nil)

    allow(tracking_service).to receive(:register)
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
