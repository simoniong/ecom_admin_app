require "application_system_test_case"

class AuthenticationSystemTest < ApplicationSystemTestCase
  test "visiting root shows login form" do
    visit root_path
    assert_selector "h2", text: "登入"
    assert_selector "input[type='email']"
    assert_selector "input[type='password']"
  end

  test "successful login shows dashboard with sidebar" do
    visit new_user_session_path
    fill_in "Email", with: "admin@example.com"
    fill_in "Password", with: "password123"
    click_button "登入"

    assert_text "Dashboard"
    assert_text "歡迎回來"
    assert_selector "aside"
    assert_link "郵箱"
    assert_link "Ticket"
  end

  test "sidebar shows user email" do
    visit new_user_session_path
    fill_in "Email", with: "admin@example.com"
    fill_in "Password", with: "password123"
    click_button "登入"

    within "aside" do
      assert_text "admin@example.com"
    end
  end

  test "navigate to email accounts page" do
    visit new_user_session_path
    fill_in "Email", with: "admin@example.com"
    fill_in "Password", with: "password123"
    click_button "登入"

    click_link "郵箱"
    assert_text "郵箱"
    assert_text "尚未綁定任何郵箱"
  end

  test "navigate to tickets page" do
    visit new_user_session_path
    fill_in "Email", with: "admin@example.com"
    fill_in "Password", with: "password123"
    click_button "登入"

    click_link "Ticket"
    assert_text "Tickets"
    assert_text "目前沒有任何 Ticket"
  end

  test "logout redirects to login page" do
    visit new_user_session_path
    fill_in "Email", with: "admin@example.com"
    fill_in "Password", with: "password123"
    click_button "登入"

    click_button "登出"
    assert_selector "h2", text: "登入"
  end

  test "login with wrong password shows error" do
    visit new_user_session_path
    fill_in "Email", with: "admin@example.com"
    fill_in "Password", with: "wrongpassword"
    click_button "登入"

    assert_text "Invalid Email or password"
  end
end
