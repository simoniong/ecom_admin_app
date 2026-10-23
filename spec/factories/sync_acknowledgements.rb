FactoryBot.define do
  factory :sync_acknowledgement do
    user
    company { user&.companies&.first || association(:company) }
    source { "shopify_metrics" }
    signature { "shopify_metrics:failed" }
    acknowledged_at { Time.current }
  end
end
