require "rails_helper"

RSpec.describe TrackingRefreshJob, type: :job do
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

  it "updates fulfillments with tracking details via update_from_tracking_result" do
    company = create(:company)
    enable_tracking(company, key: ("A" * 32))
    fulfillment = fulfillment_for(company, tracking_number: "TRACK1")
    result = {
      tracking_number: "TRACK1", status: "Delivered", sub_status: nil,
      last_event: "Delivered", last_event_time: "2026-03-25T10:00:00+08:00",
      origin_country: "CN", destination_country: "US",
      origin_carrier: "China Post", destination_carrier: "USPS",
      transit_days: 5, events: []
    }

    allow(TrackingService).to receive(:new).with(api_key: ("A" * 32)).and_return(tracking_service)
    allow(tracking_service).to receive(:register).with([ "TRACK1" ])
    allow(tracking_service).to receive(:track).with([ "TRACK1" ]).and_return([ result ])

    described_class.perform_now

    fulfillment.reload
    expect(fulfillment.tracking_status).to eq("Delivered")
    expect(fulfillment.origin_country).to eq("CN")
    expect(fulfillment.destination_country).to eq("US")
  end

  it "only polls non-terminal fulfillments" do
    company = create(:company)
    enable_tracking(company, key: ("A" * 32))
    fulfillment_for(company, tracking_number: "ACTIVE1", tracking_status: "InTransit")
    fulfillment_for(company, tracking_number: "DONE1", tracking_status: "Delivered")
    fulfillment_for(company, tracking_number: "EXPIRED1", tracking_status: "Expired")

    allow(TrackingService).to receive(:new).and_return(tracking_service)
    allow(tracking_service).to receive(:register)
    allow(tracking_service).to receive(:track).and_return([])

    described_class.perform_now

    expect(tracking_service).to have_received(:track).with([ "ACTIVE1" ])
  end

  it "registers unregistered tracking numbers before fetching" do
    company = create(:company)
    enable_tracking(company, key: ("A" * 32))
    fulfillment_for(company, tracking_number: "NEW1", tracking_details: {})
    fulfillment_for(company, tracking_number: "OLD1", tracking_details: { "status" => "InTransit" }, tracking_status: "InTransit")

    allow(TrackingService).to receive(:new).and_return(tracking_service)
    allow(tracking_service).to receive(:register).with([ "NEW1" ])
    allow(tracking_service).to receive(:track).and_return([])

    described_class.perform_now

    expect(tracking_service).to have_received(:register).with([ "NEW1" ])
  end

  it "batches tracking numbers in groups of 40" do
    company = create(:company)
    enable_tracking(company, key: ("A" * 32))
    45.times { |i| fulfillment_for(company, tracking_number: "TRACK#{i}") }

    allow(TrackingService).to receive(:new).and_return(tracking_service)
    allow(tracking_service).to receive(:register)
    allow(tracking_service).to receive(:track).and_return([])

    described_class.perform_now

    expect(tracking_service).to have_received(:track).twice
  end

  it "skips companies that have tracking disabled" do
    company = create(:company)
    fulfillment_for(company, tracking_number: "SKIP1")

    expect(TrackingService).not_to receive(:new)

    described_class.perform_now
  end

  it "skips companies whose config exists but are currently disabled" do
    company = create(:company,
                     tracking_enabled: false,
                     tracking_api_key: "A" * 32,
                     tracking_mode: "new_only",
                     tracking_starts_at: 5.days.ago)
    fulfillment_for(company, tracking_number: "SKIP1")

    expect(TrackingService).not_to receive(:new)

    described_class.perform_now
  end

  it "excludes orders placed before tracking_starts_at in new_only mode" do
    company = create(:company)
    starts_at = 1.hour.ago
    company.update!(tracking_enabled: true, tracking_api_key: ("A" * 32), tracking_mode: "new_only", tracking_starts_at: starts_at)
    fulfillment_for(company, ordered_at: starts_at + 10.minutes, tracking_number: "AFTER")
    fulfillment_for(company, ordered_at: starts_at - 10.minutes, tracking_number: "BEFORE")

    allow(TrackingService).to receive(:new).and_return(tracking_service)
    allow(tracking_service).to receive(:register)
    allow(tracking_service).to receive(:track).and_return([])

    described_class.perform_now

    expect(tracking_service).to have_received(:track).with([ "AFTER" ])
  end

  it "includes orders within 30 days in backfill mode but excludes older ones" do
    company = create(:company)
    enable_tracking(company, key: ("A" * 32), mode: "backfill", days: 30)
    fulfillment_for(company, ordered_at: 10.days.ago, tracking_number: "RECENT")
    fulfillment_for(company, ordered_at: 60.days.ago, tracking_number: "ANCIENT")

    allow(TrackingService).to receive(:new).and_return(tracking_service)
    allow(tracking_service).to receive(:register)
    allow(tracking_service).to receive(:track).and_return([])

    described_class.perform_now

    expect(tracking_service).to have_received(:track).with([ "RECENT" ])
  end

  it "includes orders of any age when all-history mode is set (starts_at is nil)" do
    company = create(:company)
    enable_tracking(company, key: ("A" * 32), mode: "backfill", days: nil)
    fulfillment_for(company, ordered_at: 2.years.ago, tracking_number: "VERY_OLD")

    allow(TrackingService).to receive(:new).and_return(tracking_service)
    allow(tracking_service).to receive(:register)
    allow(tracking_service).to receive(:track).and_return([])

    described_class.perform_now

    expect(tracking_service).to have_received(:track).with([ "VERY_OLD" ])
  end

  it "isolates API keys per company" do
    company_a = create(:company)
    company_b = create(:company)
    enable_tracking(company_a, key: ("A" * 32))
    enable_tracking(company_b, key: ("B" * 32))
    fulfillment_for(company_a, tracking_number: "A1")
    fulfillment_for(company_b, tracking_number: "B1")

    svc_a = instance_double(TrackingService)
    svc_b = instance_double(TrackingService)
    allow(TrackingService).to receive(:new).with(api_key: ("A" * 32)).and_return(svc_a)
    allow(TrackingService).to receive(:new).with(api_key: ("B" * 32)).and_return(svc_b)
    allow(svc_a).to receive(:register)
    allow(svc_b).to receive(:register)
    allow(svc_a).to receive(:track).and_return([])
    allow(svc_b).to receive(:track).and_return([])

    described_class.perform_now

    expect(svc_a).to have_received(:track).with([ "A1" ])
    expect(svc_b).to have_received(:track).with([ "B1" ])
  end

  it "continues processing other companies when one raises" do
    company_a = create(:company)
    company_b = create(:company)
    enable_tracking(company_a, key: ("A" * 32))
    enable_tracking(company_b, key: ("B" * 32))
    fulfillment_for(company_a, tracking_number: "A1")
    fulfillment_for(company_b, tracking_number: "B1")

    svc_a = instance_double(TrackingService)
    svc_b = instance_double(TrackingService)
    allow(TrackingService).to receive(:new).with(api_key: ("A" * 32)).and_return(svc_a)
    allow(TrackingService).to receive(:new).with(api_key: ("B" * 32)).and_return(svc_b)
    allow(svc_a).to receive(:register)
    allow(svc_b).to receive(:register)
    allow(svc_a).to receive(:track).and_raise(RuntimeError, "A down")
    allow(svc_b).to receive(:track).and_return([])

    expect { described_class.perform_now }.not_to raise_error
    expect(svc_b).to have_received(:track).with([ "B1" ])
  end
end
