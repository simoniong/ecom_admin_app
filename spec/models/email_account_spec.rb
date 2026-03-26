require "rails_helper"

RSpec.describe EmailAccount, type: :model do
  let(:user) { create(:user) }
  let(:account) { create(:email_account, user: user, access_token: "my-access-token", refresh_token: "my-refresh-token") }

  it "is valid with valid attributes" do
    expect(account).to be_valid
  end

  it "generates a UUID id" do
    expect(account.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  it "belongs to user" do
    expect(account.user).to eq(user)
  end

  it "requires user" do
    account = build(:email_account, user: nil)
    expect(account).not_to be_valid
  end

  it "requires email" do
    account.email = ""
    expect(account).not_to be_valid
  end

  it "enforces email uniqueness scoped to user" do
    duplicate = build(:email_account, user: user, email: account.email, google_uid: "other-uid")
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:email]).to include("has already been taken")
  end

  it "allows same email for different users" do
    other_user = create(:user)
    other_account = build(:email_account, user: other_user, email: account.email, google_uid: "other-uid")
    expect(other_account).to be_valid
  end

  it "requires google_uid" do
    account.google_uid = ""
    expect(account).not_to be_valid
  end

  it "enforces google_uid uniqueness" do
    duplicate = build(:email_account, google_uid: account.google_uid)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:google_uid]).to include("has already been taken")
  end

  it "requires access_token" do
    account.access_token = ""
    expect(account).not_to be_valid
  end

  it "requires refresh_token" do
    account.refresh_token = ""
    expect(account).not_to be_valid
  end

  it "encrypts access_token in database" do
    connection = ActiveRecord::Base.connection
    raw_value = connection.select_value(
      "SELECT access_token FROM email_accounts WHERE id = #{connection.quote(account.id)}"
    )
    expect(raw_value).not_to eq("my-access-token")
  end

  it "encrypts refresh_token in database" do
    connection = ActiveRecord::Base.connection
    raw_value = connection.select_value(
      "SELECT refresh_token FROM email_accounts WHERE id = #{connection.quote(account.id)}"
    )
    expect(raw_value).not_to eq("my-refresh-token")
  end
end
