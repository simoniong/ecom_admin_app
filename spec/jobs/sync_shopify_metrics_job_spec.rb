require "rails_helper"

RSpec.describe SyncShopifyMetricsJob, type: :job do
  it "syncs yesterday and today by default" do
    store = create(:shopify_store)

    service = instance_double(ShopifyAnalyticsService)
    allow(ShopifyAnalyticsService).to receive(:new).with(
      shop_domain: store.shop_domain,
      access_token: store.access_token,
      store_id: store.id,
      timezone: store.timezone
    ).and_return(service)
    allow(service).to receive(:sync_date)

    described_class.perform_now

    expect(service).to have_received(:sync_date).with(Date.yesterday)
    expect(service).to have_received(:sync_date).with(Date.current)
  end

  it "syncs custom number of days" do
    store = create(:shopify_store)

    service = instance_double(ShopifyAnalyticsService)
    allow(ShopifyAnalyticsService).to receive(:new).and_return(service)
    allow(service).to receive(:sync_date)

    described_class.perform_now(days: 7)

    expect(service).to have_received(:sync_date).exactly(8).times # 7 days ago..today = 8 days
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

  it "records a succeeded auto run per store" do
    store = create(:shopify_store)

    service = instance_double(ShopifyAnalyticsService)
    allow(ShopifyAnalyticsService).to receive(:new).and_return(service)
    allow(service).to receive(:sync_date)

    described_class.perform_now

    run = SyncRun.where(source: "shopify_metrics", target: store).last
    expect(run.status).to eq("succeeded")
    expect(run.trigger).to eq("auto")
  end

  it "records a failed run when any date fails and still processes the other stores" do
    store_a = create(:shopify_store)
    store_b = create(:shopify_store)

    service_a = instance_double(ShopifyAnalyticsService)
    service_b = instance_double(ShopifyAnalyticsService)
    allow(ShopifyAnalyticsService).to receive(:new).with(hash_including(store_id: store_a.id)).and_return(service_a)
    allow(ShopifyAnalyticsService).to receive(:new).with(hash_including(store_id: store_b.id)).and_return(service_b)
    allow(service_a).to receive(:sync_date).and_raise(RuntimeError, "API error")
    allow(service_b).to receive(:sync_date)

    expect { described_class.perform_now }.not_to raise_error

    run_a = SyncRun.where(source: "shopify_metrics", target: store_a).last
    run_b = SyncRun.where(source: "shopify_metrics", target: store_b).last
    expect(run_a.status).to eq("failed")
    expect(run_a.error_message).to include("API error")
    expect(run_b.status).to eq("succeeded")
  end

  it "limits to store_ids and records trigger manual" do
    store_a = create(:shopify_store)
    store_b = create(:shopify_store)

    service = instance_double(ShopifyAnalyticsService)
    allow(ShopifyAnalyticsService).to receive(:new).and_return(service)
    allow(service).to receive(:sync_date)

    described_class.perform_now(store_ids: [ store_a.id ], trigger: "manual")

    expect(SyncRun.where(source: "shopify_metrics", target: store_a).last.trigger).to eq("manual")
    expect(SyncRun.where(source: "shopify_metrics", target: store_b)).to be_empty
  end
end
