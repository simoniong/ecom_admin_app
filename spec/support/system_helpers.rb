module SystemHelpers
  def sign_in_via_form(user, password: "password123")
    visit new_user_session_path
    expect(page).to have_selector("input[type='email']", wait: 5)
    fill_in "Email", with: user.email
    fill_in "Password", with: password
    click_button "Sign in"
    expect(page).to have_text("Dashboard", wait: 10)
  end
end

RSpec.configure do |config|
  config.include SystemHelpers, type: :system
end
