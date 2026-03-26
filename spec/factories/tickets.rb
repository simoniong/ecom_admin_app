FactoryBot.define do
  factory :ticket do
    email_account
    sequence(:gmail_thread_id) { |n| "thread-#{n}" }
    subject { "Test ticket subject" }
    customer_email { "customer@example.com" }
    customer_name { "Test Customer" }
    status { :new_ticket }
    last_message_at { Time.current }
  end
end
