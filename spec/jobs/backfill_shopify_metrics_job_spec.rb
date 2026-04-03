require "rails_helper"

RSpec.describe BackfillShopifyMetricsJob, type: :job do
  it "syncs 90 days of metrics for the store" do
    store = create(:shopify_store)

    service = instance_double(ShopifyAnalyticsService)
    allow(ShopifyAnalyticsService).to receive(:new).with(
      shop_domain: store.shop_domain,
      access_token: store.access_token,
      store_id: store.id,
      timezone: store.timezone
    ).and_return(service)
    allow(service).to receive(:sync_date)

    described_class.perform_now(store.id)

    expect(service).to have_received(:sync_date).exactly(91).times # 90 days ago..today = 91 days
  end

  it "accepts custom days parameter" do
    store = create(:shopify_store)

    service = instance_double(ShopifyAnalyticsService)
    allow(ShopifyAnalyticsService).to receive(:new).and_return(service)
    allow(service).to receive(:sync_date)

    described_class.perform_now(store.id, days: 7)

    expect(service).to have_received(:sync_date).exactly(8).times
  end

  it "does nothing when store not found" do
    expect(ShopifyAnalyticsService).not_to receive(:new)
    described_class.perform_now("nonexistent-id")
  end

  it "handles errors per date gracefully" do
    store = create(:shopify_store)

    service = instance_double(ShopifyAnalyticsService)
    allow(ShopifyAnalyticsService).to receive(:new).and_return(service)
    allow(service).to receive(:sync_date).and_raise(RuntimeError, "API error")

    expect { described_class.perform_now(store.id, days: 2) }.not_to raise_error
  end
end
