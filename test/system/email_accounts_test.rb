require "application_system_test_case"

class EmailAccountsSystemTest < ApplicationSystemTestCase
  test "email accounts page shows bind new button" do
    visit new_user_session_path
    fill_in "Email", with: "admin@example.com"
    fill_in "Password", with: ADMIN_TEST_PASSWORD
    click_button "Sign in"

    click_link "Email Accounts"
    assert_button "Bind New Email"
  end

  test "email accounts page shows empty state" do
    visit new_user_session_path
    fill_in "Email", with: "admin@example.com"
    fill_in "Password", with: ADMIN_TEST_PASSWORD
    click_button "Sign in"

    click_link "Email Accounts"
    assert_text "No email accounts linked yet."
  end

  test "oauth flow binds email and shows in list" do
    visit new_user_session_path
    fill_in "Email", with: "admin@example.com"
    fill_in "Password", with: ADMIN_TEST_PASSWORD
    click_button "Sign in"

    click_link "Email Accounts"
    click_button "Bind New Email"

    assert_text "Email account bound successfully."
    assert_text "oauth-test@gmail.com"
    assert_text "Connected"
  end
end
