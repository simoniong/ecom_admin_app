require "rails_helper"

RSpec.describe CarrierChangeJob, type: :job do
  let(:company) do
    create(:company, tracking_enabled: true, tracking_api_key: ("A" * 32),
           tracking_mode: "new_only", tracking_starts_at: Time.current)
  end
  let(:store) { create(:shopify_store, company: company) }
  let(:order) { create(:order, shopify_store: store) }
  let!(:fulfillment) { create(:fulfillment, order: order, tracking_number: "RR1", tracking_status: "InTransit") }

  let(:service) { instance_double(TrackingService) }

  before do
    allow(TrackingService).to receive(:new).with(api_key: "A" * 32).and_return(service)
    allow(service).to receive(:change_carrier).and_return(accepted: [ "RR1" ], rejected: [])
    allow(service).to receive(:register).and_return([])
    allow(service).to receive(:track).and_return([
      { tracking_number: "RR1", status: "InTransit", sub_status: "InTransit_Other",
        origin_carrier: "China Post", destination_carrier: nil, origin_country: "CN",
        destination_country: "US", transit_days: 5, last_event: "Accepted",
        last_event_time: "2026-06-13T08:00:00+08:00", events: [] }
    ])
  end

  it "calls change_carrier with the selected numbers and code" do
    described_class.perform_now(company.id, [ fulfillment.id ], 3011)
    expect(service).to have_received(:change_carrier).with([ "RR1" ], carrier_new: 3011)
  end

  it "persists carrier_code on the fulfillment" do
    described_class.perform_now(company.id, [ fulfillment.id ], 3011)
    expect(fulfillment.reload.carrier_code).to eq(3011)
  end

  it "re-tracks and applies the result" do
    described_class.perform_now(company.id, [ fulfillment.id ], 3011)
    expect(fulfillment.reload.origin_carrier).to eq("China Post")
    expect(service).to have_received(:track).with([ "RR1" ])
  end

  it "falls back to register for rejected numbers" do
    allow(service).to receive(:change_carrier)
      .and_return(accepted: [], rejected: [ { number: "RR1", code: -18019902 } ])

    described_class.perform_now(company.id, [ fulfillment.id ], 3011)
    expect(service).to have_received(:register).with([ "RR1" ], carrier: 3011, auto_detection: false)
  end

  it "persists carrier_code when the register fallback succeeds" do
    allow(service).to receive(:change_carrier)
      .and_return(accepted: [], rejected: [ { number: "RR1", code: -18019902 } ])
    allow(service).to receive(:register).and_return([ { "number" => "RR1" } ])

    described_class.perform_now(company.id, [ fulfillment.id ], 3011)
    expect(fulfillment.reload.carrier_code).to eq(3011)
  end

  it "does not persist carrier_code when change and register both fail" do
    allow(service).to receive(:change_carrier)
      .and_return(accepted: [], rejected: [ { number: "RR1", code: -18019902 } ])
    allow(service).to receive(:register).and_return([])

    described_class.perform_now(company.id, [ fulfillment.id ], 3011)
    expect(fulfillment.reload.carrier_code).to be_nil
  end

  it "does nothing when no scoped fulfillments match" do
    expect(TrackingService).not_to receive(:new)
    described_class.perform_now(company.id, [], 3011)
  end

  it "does nothing when tracking disabled" do
    disabled = create(:company)
    expect(TrackingService).not_to receive(:new)
    described_class.perform_now(disabled.id, [ fulfillment.id ], 3011)
  end

  it "ignores fulfillments outside the company's stores" do
    other_store = create(:shopify_store, company: create(:company))
    other_f = create(:fulfillment, order: create(:order, shopify_store: other_store), tracking_number: "X9")
    described_class.perform_now(company.id, [ fulfillment.id, other_f.id ], 3011)
    expect(service).to have_received(:change_carrier).with([ "RR1" ], carrier_new: 3011)
  end
end
