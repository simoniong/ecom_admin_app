FactoryBot.define do
  factory :sync_run do
    target factory: :shopify_store
    company { target.company }
    source { "shopify_metrics" }
    trigger { "auto" }
    status { "succeeded" }
    started_at { Time.current }
    finished_at { Time.current }

    # A row the Dashboard's Sync action pre-created for a job it is about to
    # enqueue, waiting for that job to claim it.
    trait :placeholder do
      placeholder { true }
      batch_id { SecureRandom.uuid }
      trigger { "manual" }
      status { "running" }
      finished_at { nil }
    end
  end
end
