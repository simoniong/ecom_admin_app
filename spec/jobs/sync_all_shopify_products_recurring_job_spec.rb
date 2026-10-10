require "rails_helper"

RSpec.describe SyncAllShopifyProductsRecurringJob, type: :job do
  it "syncs products for each store" do
    store = create(:shopify_store)
    service = instance_double(SyncShopifyProductsService)
    allow(SyncShopifyProductsService).to receive(:new).with(store).and_return(service)
    allow(service).to receive(:call).and_return(products: 0, variants: 0)

    described_class.perform_now

    expect(service).to have_received(:call)
  end

  it "continues when a store fails" do
    store1 = create(:shopify_store)
    store2 = create(:shopify_store)

    service1 = instance_double(SyncShopifyProductsService)
    service2 = instance_double(SyncShopifyProductsService)

    allow(SyncShopifyProductsService).to receive(:new).with(store1).and_return(service1)
    allow(SyncShopifyProductsService).to receive(:new).with(store2).and_return(service2)
    allow(service1).to receive(:call).and_raise(RuntimeError, "API error")
    allow(service2).to receive(:call).and_return(products: 0, variants: 0)

    expect { described_class.perform_now }.not_to raise_error
    expect(service2).to have_received(:call)
  end

  it "does nothing when no stores exist" do
    expect(SyncShopifyProductsService).not_to receive(:new)
    described_class.perform_now
  end
end
