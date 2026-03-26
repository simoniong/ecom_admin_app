FactoryBot.define do
  factory :ticket do
    email_account
    sequence(:gmail_thread_id) { |n| "thread-#{n}" }
    subject { "Test ticket subject" }
    customer_email { "customer@example.com" }
    customer_name { "Test Customer" }
    status { :new_ticket }
    last_message_at { Time.current }

    trait :draft do
      status { :draft }
      draft_reply { "Agent generated draft reply" }
      draft_reply_at { Time.current }
    end

    trait :draft_confirmed do
      status { :draft_confirmed }
      draft_reply { "Confirmed draft reply" }
      draft_reply_at { Time.current }
    end

    trait :closed do
      status { :closed }
    end
  end
end
