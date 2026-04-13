FactoryBot.define do
  factory :email_workflow do
    shopify_store
    trigger_event { "order_shipped" }
    enabled { true }
  end
end
