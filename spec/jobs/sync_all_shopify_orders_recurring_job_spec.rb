require "rails_helper"

RSpec.describe SyncAllShopifyOrdersRecurringJob, type: :job do
  it "syncs each store with incremental when orders_synced_at present" do
    store = create(:shopify_store, orders_synced_at: 1.hour.ago)
    service = instance_double(SyncAllOrdersService)
    allow(SyncAllOrdersService).to receive(:new).with(store).and_return(service)
    allow(service).to receive(:call).and_return(customers: 0, orders: 0)

    described_class.perform_now

    expect(service).to have_received(:call).with(incremental: true)
  end

  it "does full sync when orders_synced_at is nil" do
    store = create(:shopify_store, orders_synced_at: nil)
    service = instance_double(SyncAllOrdersService)
    allow(SyncAllOrdersService).to receive(:new).with(store).and_return(service)
    allow(service).to receive(:call).and_return(customers: 0, orders: 0)

    described_class.perform_now

    expect(service).to have_received(:call).with(incremental: false)
  end

  it "continues when a store fails" do
    store1 = create(:shopify_store)
    store2 = create(:shopify_store)

    service1 = instance_double(SyncAllOrdersService)
    service2 = instance_double(SyncAllOrdersService)

    allow(SyncAllOrdersService).to receive(:new).with(store1).and_return(service1)
    allow(SyncAllOrdersService).to receive(:new).with(store2).and_return(service2)
    allow(service1).to receive(:call).and_raise(RuntimeError, "API error")
    allow(service2).to receive(:call).and_return(customers: 0, orders: 0)

    expect { described_class.perform_now }.not_to raise_error
    expect(service2).to have_received(:call)
  end

  it "does nothing when no stores exist" do
    expect(SyncAllOrdersService).not_to receive(:new)
    described_class.perform_now
  end
end
