require "test_helper"

class EmailAccountTest < ActiveSupport::TestCase
  setup do
    @user = users(:email_user)
    @account = @user.email_accounts.create!(
      email: "model-test@gmail.com",
      google_uid: "model-test-uid",
      access_token: "model-access-token",
      refresh_token: "model-refresh-token",
      token_expires_at: 1.hour.from_now
    )
  end

  test "valid account" do
    assert @account.valid?
  end

  test "id is a uuid" do
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, @account.id)
  end

  test "belongs to user" do
    assert_equal @user, @account.user
  end

  test "user is required" do
    account = EmailAccount.new(
      email: "test@gmail.com",
      google_uid: "uid-new",
      access_token: "token",
      refresh_token: "refresh"
    )
    assert_not account.valid?
  end

  test "email is required" do
    @account.email = ""
    assert_not @account.valid?
  end

  test "email uniqueness scoped to user" do
    duplicate = EmailAccount.new(
      user: @user,
      email: @account.email,
      google_uid: "different-uid",
      access_token: "token",
      refresh_token: "refresh"
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:email], "has already been taken"
  end

  test "same email allowed for different users" do
    account = EmailAccount.new(
      user: users(:admin),
      email: @account.email,
      google_uid: "different-uid",
      access_token: "token",
      refresh_token: "refresh"
    )
    assert account.valid?
  end

  test "google_uid is required" do
    @account.google_uid = ""
    assert_not @account.valid?
  end

  test "google_uid must be unique" do
    duplicate = EmailAccount.new(
      user: users(:admin),
      email: "other@gmail.com",
      google_uid: @account.google_uid,
      access_token: "token",
      refresh_token: "refresh"
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:google_uid], "has already been taken"
  end

  test "access_token is required" do
    @account.access_token = ""
    assert_not @account.valid?
  end

  test "refresh_token is required" do
    @account.refresh_token = ""
    assert_not @account.valid?
  end

  test "access_token is encrypted in database" do
    connection = ActiveRecord::Base.connection
    raw_value = connection.select_value(
      "SELECT access_token FROM email_accounts WHERE id = #{connection.quote(@account.id)}"
    )
    assert_not_equal "model-access-token", raw_value
  end

  test "refresh_token is encrypted in database" do
    connection = ActiveRecord::Base.connection
    raw_value = connection.select_value(
      "SELECT refresh_token FROM email_accounts WHERE id = #{connection.quote(@account.id)}"
    )
    assert_not_equal "model-refresh-token", raw_value
  end

  test "destroying user destroys email accounts" do
    user = User.create!(email: "destroy-test@example.com", password: "password123", password_confirmation: "password123")
    user.email_accounts.create!(
      email: "destroy@gmail.com",
      google_uid: "destroy-uid",
      access_token: "token",
      refresh_token: "refresh"
    )
    assert_difference "EmailAccount.count", -1 do
      user.destroy
    end
  end
end
