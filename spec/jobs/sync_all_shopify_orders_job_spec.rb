require "rails_helper"

RSpec.describe SyncAllShopifyOrdersJob, type: :job do
  it "calls SyncAllOrdersService with incremental when orders_synced_at present" do
    store = create(:shopify_store, orders_synced_at: 1.hour.ago)
    service = instance_double(SyncAllOrdersService)
    allow(SyncAllOrdersService).to receive(:new).with(store).and_return(service)
    allow(service).to receive(:call).and_return(customers: 0, orders: 0)

    described_class.perform_now(store.id)

    expect(service).to have_received(:call).with(incremental: true)
  end

  it "does full sync when orders_synced_at is nil" do
    store = create(:shopify_store, orders_synced_at: nil)
    service = instance_double(SyncAllOrdersService)
    allow(SyncAllOrdersService).to receive(:new).with(store).and_return(service)
    allow(service).to receive(:call).and_return(customers: 0, orders: 0)

    described_class.perform_now(store.id)

    expect(service).to have_received(:call).with(incremental: false)
  end

  it "does full sync when full: true" do
    store = create(:shopify_store, orders_synced_at: 1.hour.ago)
    service = instance_double(SyncAllOrdersService)
    allow(SyncAllOrdersService).to receive(:new).with(store).and_return(service)
    allow(service).to receive(:call).and_return(customers: 0, orders: 0)

    described_class.perform_now(store.id, full: true)

    expect(service).to have_received(:call).with(incremental: false)
  end

  it "does nothing when store not found" do
    expect(SyncAllOrdersService).not_to receive(:new)
    described_class.perform_now("nonexistent-id")
  end

  it "handles errors gracefully without re-raising" do
    store = create(:shopify_store)
    allow(SyncAllOrdersService).to receive(:new).and_raise(RuntimeError, "API error")

    expect { described_class.perform_now(store.id) }.not_to raise_error
  end
end
