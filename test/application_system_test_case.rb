require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 900 ]

  def sign_in_as_admin
    visit new_user_session_path
    fill_in "Email", with: users(:admin).email
    fill_in "Password", with: ADMIN_TEST_PASSWORD
    click_button "Sign in"
  end

  setup do
    ENV["no_proxy"] = "localhost,127.0.0.1"
    ENV["NO_PROXY"] = "localhost,127.0.0.1"
  end
end
