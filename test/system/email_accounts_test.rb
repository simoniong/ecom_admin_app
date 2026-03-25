require "application_system_test_case"

class EmailAccountsSystemTest < ApplicationSystemTestCase
  test "email accounts page shows bind new button" do
    sign_in_as_admin
    click_link "Email Accounts"
    assert_button "Bind New Email"
  end

  test "email accounts page shows empty state" do
    sign_in_as_admin
    click_link "Email Accounts"
    assert_text "No email accounts linked yet."
  end

  test "oauth flow binds email and shows in list" do
    sign_in_as_admin
    click_link "Email Accounts"
    click_button "Bind New Email"

    assert_text "Email account bound successfully."
    assert_text "oauth-test@gmail.com"
    assert_text "Connected"
  end

  test "clicking account navigates to show page" do
    sign_in_as_admin
    click_link "Email Accounts"
    click_button "Bind New Email"
    click_link "oauth-test@gmail.com"

    assert_text "Access Token"
    assert_text "Refresh Token"
    assert_text "Connected At"
    assert_button "Disconnect"
  end

  test "disconnect removes account and returns to list" do
    sign_in_as_admin
    click_link "Email Accounts"
    click_button "Bind New Email"
    click_link "oauth-test@gmail.com"

    accept_confirm do
      click_button "Disconnect"
    end

    assert_text "Email account disconnected successfully."
    assert_text "No email accounts linked yet."
  end
end
