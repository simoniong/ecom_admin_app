require "test_helper"

class EmailAccountsTest < ActionDispatch::IntegrationTest
  test "authenticated user can access email accounts index" do
    sign_in users(:admin)
    get email_accounts_path
    assert_response :success
  end

  test "unauthenticated user is redirected" do
    get email_accounts_path
    assert_redirected_to new_user_session_path
  end

  test "index shows bind new email button" do
    sign_in users(:admin)
    get email_accounts_path
    assert_select "button", text: /Bind New Email/
  end

  test "index lists bound email accounts" do
    user = users(:email_user)
    user.email_accounts.create!(
      email: "listed@gmail.com",
      google_uid: "list-uid",
      access_token: "token",
      refresh_token: "refresh"
    )
    sign_in user
    get email_accounts_path
    assert_select "span", text: "listed@gmail.com"
  end

  test "index shows empty state when no accounts" do
    sign_in users(:admin)
    get email_accounts_path
    assert_select "p", text: "No email accounts linked yet."
  end

  test "oauth callback creates email account" do
    sign_in users(:admin)

    assert_difference "EmailAccount.count", 1 do
      get "/auth/google_oauth2/callback"
    end

    account = users(:admin).email_accounts.last
    assert_equal "oauth-test@gmail.com", account.email
    assert_equal "google-uid-999", account.google_uid
    assert_redirected_to email_accounts_path
    follow_redirect!
    assert_select "span", text: "oauth-test@gmail.com"
  end

  test "oauth callback updates existing account on re-bind" do
    user = users(:email_user)
    existing = user.email_accounts.create!(
      email: "rebind@gmail.com",
      google_uid: "rebind-uid",
      access_token: "old-token",
      refresh_token: "old-refresh"
    )

    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "rebind-uid",
      info: { email: "rebind@gmail.com", name: "Rebind User" },
      credentials: {
        token: "new-access-token",
        refresh_token: "new-refresh-token",
        expires_at: 2.hours.from_now.to_i
      }
    )

    sign_in user
    assert_no_difference "EmailAccount.count" do
      get "/auth/google_oauth2/callback"
    end

    existing.reload
    assert_equal "new-access-token", existing.access_token
    assert_redirected_to email_accounts_path
  end

  test "show displays email account details" do
    user = users(:email_user)
    account = user.email_accounts.create!(
      email: "show@gmail.com",
      google_uid: "show-uid",
      access_token: "show-token",
      refresh_token: "show-refresh",
      token_expires_at: 1.hour.from_now,
      scopes: "email,profile"
    )
    sign_in user
    get email_account_path(id: account.id)
    assert_response :success
    assert_select "dd", text: "show@gmail.com"
    assert_select "dd", text: "show-uid"
    assert_select "dd", text: "show-token"
    assert_select "dd", text: "show-refresh"
  end

  test "show is scoped to current user" do
    other_user = users(:email_user)
    account = other_user.email_accounts.create!(
      email: "other@gmail.com",
      google_uid: "other-uid",
      access_token: "token",
      refresh_token: "refresh"
    )
    sign_in users(:admin)
    get email_account_path(id: account.id)
    assert_response :not_found
  end

  test "destroy disconnects email account" do
    user = users(:email_user)
    account = user.email_accounts.create!(
      email: "destroy@gmail.com",
      google_uid: "destroy-uid",
      access_token: "token",
      refresh_token: "refresh"
    )
    sign_in user
    assert_difference "EmailAccount.count", -1 do
      delete email_account_path(id: account.id)
    end
    assert_redirected_to email_accounts_path
    follow_redirect!
    assert_select "p", text: /disconnected successfully/
  end

  test "destroy is scoped to current user" do
    other_user = users(:email_user)
    account = other_user.email_accounts.create!(
      email: "notmine@gmail.com",
      google_uid: "notmine-uid",
      access_token: "token",
      refresh_token: "refresh"
    )
    sign_in users(:admin)
    delete email_account_path(id: account.id)
    assert_response :not_found
  end

  test "oauth failure redirects with alert" do
    sign_in users(:admin)
    get "/auth/failure"
    assert_redirected_to email_accounts_path
    follow_redirect!
    assert_select "p", text: /Google authentication failed/
  end

  teardown do
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
