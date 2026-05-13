require "rails_helper"
require "rake"

RSpec.describe "shopify:backfill_new_customer_orders", type: :task do
  before(:all) do
    Rake.application.rake_require("tasks/shopify_backfill", [ Rails.root.join("lib").to_s ])
    Rake::Task.define_task(:environment)
  end

  let(:task) { Rake::Task["shopify:backfill_new_customer_orders"] }

  before { task.reenable }

  it "calls sync_date on each active store for each date in the window" do
    store_a = create(:shopify_store, shop_domain: "a.myshopify.com")
    store_b = create(:shopify_store, shop_domain: "b.myshopify.com")

    instance_a = instance_double(ShopifyAnalyticsService)
    instance_b = instance_double(ShopifyAnalyticsService)
    allow(ShopifyAnalyticsService).to receive(:new).with(hash_including(store_id: store_a.id)).and_return(instance_a)
    allow(ShopifyAnalyticsService).to receive(:new).with(hash_including(store_id: store_b.id)).and_return(instance_b)
    expect(instance_a).to receive(:sync_date).exactly(3).times
    expect(instance_b).to receive(:sync_date).exactly(3).times

    task.invoke("3")
  end

  it "defaults to 90 days when no argument is passed" do
    create(:shopify_store)
    instance = instance_double(ShopifyAnalyticsService)
    allow(ShopifyAnalyticsService).to receive(:new).and_return(instance)
    expect(instance).to receive(:sync_date).exactly(90).times

    task.invoke
  end

  it "continues to the next iteration when one sync raises" do
    create(:shopify_store)
    instance = instance_double(ShopifyAnalyticsService)
    allow(ShopifyAnalyticsService).to receive(:new).and_return(instance)
    expect(instance).to receive(:sync_date).exactly(2).times.and_raise(StandardError, "boom")

    expect { task.invoke("2") }.not_to raise_error
  end

  it "aborts with a clear message when days argument is not a positive integer" do
    create(:shopify_store)
    expect(ShopifyAnalyticsService).not_to receive(:new)

    expect { task.invoke("abc") }.to raise_error(SystemExit, /positive integer days argument/)
  end
end
