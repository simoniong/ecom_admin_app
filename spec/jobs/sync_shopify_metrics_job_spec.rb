require "rails_helper"

RSpec.describe SyncShopifyMetricsJob, type: :job do
  it "syncs metrics for each store" do
    store = create(:shopify_store)

    service = instance_double(ShopifyAnalyticsService)
    allow(ShopifyAnalyticsService).to receive(:new).with(
      shop_domain: store.shop_domain,
      access_token: store.access_token,
      store_id: store.id
    ).and_return(service)
    allow(service).to receive(:sync_date)

    described_class.perform_now

    expect(service).to have_received(:sync_date).with(Date.yesterday)
    expect(service).to have_received(:sync_date).with(Date.current)
  end

  it "handles errors gracefully" do
    create(:shopify_store)

    service = instance_double(ShopifyAnalyticsService)
    allow(ShopifyAnalyticsService).to receive(:new).and_return(service)
    allow(service).to receive(:sync_date).and_raise(RuntimeError, "API error")

    expect { described_class.perform_now }.not_to raise_error
  end

  it "does nothing when no stores exist" do
    expect(ShopifyAnalyticsService).not_to receive(:new)
    described_class.perform_now
  end
end
