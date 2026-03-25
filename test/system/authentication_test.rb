require "application_system_test_case"

class AuthenticationSystemTest < ApplicationSystemTestCase
  test "visiting root shows login form" do
    visit root_path
    assert_selector "h2", text: "Sign in"
    assert_selector "input[type='email']"
    assert_selector "input[type='password']"
  end

  test "successful login shows dashboard with sidebar" do
    sign_in_as_admin

    assert_text "Dashboard"
    assert_text "Welcome back"
    assert_selector "aside"
    assert_link "Email Accounts"
    assert_link "Tickets"
  end

  test "sidebar shows user email" do
    sign_in_as_admin

    within "aside" do
      assert_text users(:admin).email
    end
  end

  test "navigate to email accounts page" do
    sign_in_as_admin

    click_link "Email Accounts"
    assert_text "Email Accounts"
    assert_text "No email accounts linked yet."
  end

  test "navigate to tickets page" do
    sign_in_as_admin

    click_link "Tickets"
    assert_text "Tickets"
    assert_text "No tickets yet."
  end

  test "logout redirects to login page" do
    sign_in_as_admin

    click_button "Sign out"
    assert_selector "h2", text: "Sign in"
  end

  test "login with wrong password shows error" do
    visit new_user_session_path
    fill_in "Email", with: users(:admin).email
    fill_in "Password", with: "wrongpassword"
    click_button "Sign in"

    assert_text "Invalid email or password."
  end
end
