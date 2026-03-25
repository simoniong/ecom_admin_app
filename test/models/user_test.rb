require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "valid user creation" do
    user = User.new(email: "test@example.com", password: "password123", password_confirmation: "password123")
    assert user.valid?
    assert user.save
  end

  test "id is a uuid" do
    user = User.create!(email: "uuid@example.com", password: "password123", password_confirmation: "password123")
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, user.id)
  end

  test "email must be unique" do
    User.create!(email: "dup@example.com", password: "password123", password_confirmation: "password123")
    user = User.new(email: "dup@example.com", password: "password123", password_confirmation: "password123")
    assert_not user.valid?
    assert_includes user.errors[:email], "has already been taken"
  end

  test "email must be present" do
    user = User.new(email: "", password: "password123")
    assert_not user.valid?
  end

  test "email must have valid format" do
    user = User.new(email: "notanemail", password: "password123")
    assert_not user.valid?
  end

  test "password must be at least 6 characters" do
    user = User.new(email: "short@example.com", password: "12345", password_confirmation: "12345")
    assert_not user.valid?
    assert_includes user.errors[:password], "is too short (minimum is 6 characters)"
  end

  test "lock_access! locks the account" do
    user = User.create!(email: "lock@example.com", password: "password123", password_confirmation: "password123")
    assert_not user.access_locked?
    user.lock_access!(send_instructions: false)
    assert user.access_locked?
    assert_not_nil user.locked_at
  end

  test "locked account unlocks after unlock_in period" do
    user = User.create!(email: "unlock@example.com", password: "password123", password_confirmation: "password123")
    user.lock_access!(send_instructions: false)
    assert user.access_locked?

    travel(Devise.unlock_in + 1.minute) do
      assert_not user.access_locked?
    end
  end
end
