FactoryBot.define do
  factory :email_account do
    user
    sequence(:email) { |n| "account#{n}@gmail.com" }
    sequence(:google_uid) { |n| "google-uid-#{n}" }
    access_token { "test-access-token" }
    refresh_token { "test-refresh-token" }
    token_expires_at { 1.hour.from_now }
    scopes { "email,profile" }
  end
end
