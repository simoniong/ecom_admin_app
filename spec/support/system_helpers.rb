module SystemHelpers
  def sign_in_via_form(user, password: "password123")
    visit new_user_session_path
    fill_in "Email", with: user.email
    fill_in "Password", with: password
    click_button "Sign in"
  end
end

RSpec.configure do |config|
  config.include SystemHelpers, type: :system
end
