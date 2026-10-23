FactoryBot.define do
  factory :sync_run do
    target factory: :shopify_store
    company { target.company }
    source { "shopify_metrics" }
    trigger { "auto" }
    status { "succeeded" }
    started_at { Time.current }
    finished_at { Time.current }
  end
end
