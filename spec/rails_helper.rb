require "simplecov"
SimpleCov.start "rails" do
  enable_coverage :branch
end

require "spec_helper"
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
abort("The Rails environment is running in production mode!") if Rails.env.production?
require "rspec/rails"
require "webmock/rspec"

WebMock.disable_net_connect!(allow_localhost: true)

Dir[Rails.root.join("spec/support/**/*.rb")].each { |f| require f }

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

OmniAuth.config.test_mode = true
OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
  provider: "google_oauth2",
  uid: "google-uid-999",
  info: { email: "oauth-test@gmail.com", name: "Test User" },
  credentials: {
    token: "mock-access-token",
    refresh_token: "mock-refresh-token",
    expires_at: 1.hour.from_now.to_i,
    scope: "email profile https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/gmail.modify"
  }
)

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include FactoryBot::Syntax::Methods
  config.include ActiveSupport::Testing::TimeHelpers
  config.include Devise::Test::IntegrationHelpers, type: :request

  config.before(:each, type: :system) do
    ENV["no_proxy"] = "localhost,127.0.0.1"
    ENV["NO_PROXY"] = "localhost,127.0.0.1"
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 900 ]
  end

  config.after(:each) do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "google-uid-999",
      info: { email: "oauth-test@gmail.com", name: "Test User" },
      credentials: {
        token: "mock-access-token",
        refresh_token: "mock-refresh-token",
        expires_at: 1.hour.from_now.to_i,
        scope: "email profile https://www.googleapis.com/auth/gmail.readonly https://www.googleapis.com/auth/gmail.send https://www.googleapis.com/auth/gmail.modify"
      }
    )
  end
end
