FactoryBot.define do
  factory :message do
    ticket
    sequence(:gmail_message_id) { |n| "msg-#{n}" }
    from { "customer@example.com" }
    to { "support@example.com" }
    subject { "Test message" }
    body { "This is a test message body." }
    sent_at { Time.current }
    gmail_internal_date { (Time.current.to_f * 1000).to_i }
  end
end
