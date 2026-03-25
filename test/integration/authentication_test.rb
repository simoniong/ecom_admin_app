require "test_helper"

class AuthenticationTest < ActionDispatch::IntegrationTest
  test "unauthenticated user sees login page at root" do
    get root_path
    assert_response :success
    assert_select "h2", "Sign in"
  end

  test "login with valid credentials" do
    sign_in users(:admin)
    get authenticated_root_path
    assert_response :success
  end

  test "login via form with valid credentials" do
    post user_session_path, params: {
      user: { email: "admin@example.com", password: "password123" }
    }
    assert_redirected_to authenticated_root_path
    follow_redirect!
    assert_response :success
  end

  test "login via form with invalid credentials" do
    post user_session_path, params: {
      user: { email: "admin@example.com", password: "wrongpassword" }
    }
    assert_response :unprocessable_entity
  end

  test "logout redirects to login" do
    sign_in users(:admin)
    delete destroy_user_session_path
    assert_redirected_to root_path
  end

  test "authenticated user can access email accounts" do
    sign_in users(:admin)
    get email_accounts_path
    assert_response :success
  end

  test "authenticated user can access tickets" do
    sign_in users(:admin)
    get tickets_path
    assert_response :success
  end

  test "unauthenticated user cannot access email accounts" do
    get email_accounts_path
    assert_redirected_to new_user_session_path
  end

  test "unauthenticated user cannot access tickets" do
    get tickets_path
    assert_redirected_to new_user_session_path
  end

  test "account locks after maximum failed attempts" do
    Devise.maximum_attempts.times do
      post user_session_path, params: {
        user: { email: "admin@example.com", password: "wrongpassword" }
      }
    end

    post user_session_path, params: {
      user: { email: "admin@example.com", password: "password123" }
    }
    assert_response :unprocessable_entity
  end
end
