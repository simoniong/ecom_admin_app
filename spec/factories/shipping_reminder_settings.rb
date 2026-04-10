FactoryBot.define do
  factory :shipping_reminder_setting do
    company
    enabled { true }
    recipients { [ "admin@example.com" ] }
    timezone { "UTC" }
    send_hour { 9 }
    frequency { "every_day" }
  end
end
