module SystemHelpers
  def sign_in_via_form(user, password: "password123")
    visit new_user_session_path
    expect(page).to have_selector("h2", text: "Sign in", wait: 10)
    fill_in "Email", with: user.email
    fill_in "Password", with: password
    click_button "Sign in"
    expect(page).to have_selector("aside", wait: 15)
  end

  # Rack-level sign in — fast and reliable for tests that only need an authenticated session
  def sign_in_as(user)
    login_as(user, scope: :user)
    visit root_path
    expect(page).to have_selector("aside", wait: 10)
  end
end

RSpec.configure do |config|
  config.include SystemHelpers, type: :system
  config.include Warden::Test::Helpers, type: :system
  config.after(:each, type: :system) { Warden.test_reset! }
end
