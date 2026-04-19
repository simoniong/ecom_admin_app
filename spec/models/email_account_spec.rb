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

  describe "agent_api_key" do
    it "is auto-generated on create" do
      new_account = create(:email_account)
      expect(new_account.agent_api_key).to be_present
      expect(new_account.agent_api_key.length).to be >= 32
    end

    it "generates unique keys for different accounts" do
      a1 = create(:email_account)
      a2 = create(:email_account)
      expect(a1.agent_api_key).not_to eq(a2.agent_api_key)
    end

    it "keeps the key stable across updates" do
      original = account.agent_api_key
      account.update!(scopes: "email")
      expect(account.reload.agent_api_key).to eq(original)
    end

    it "respects a key assigned before creation" do
      new_account = build(:email_account, user: create(:user), agent_api_key: "preset-key-value")
      new_account.save!
      expect(new_account.agent_api_key).to eq("preset-key-value")
    end

    it "rejects duplicate keys" do
      dup = build(:email_account, agent_api_key: account.agent_api_key)
      expect(dup).not_to be_valid
      expect(dup.errors[:agent_api_key]).to include("has already been taken")
    end

    it "stores the key encrypted at rest" do
      connection = ActiveRecord::Base.connection
      raw = connection.select_value(
        "SELECT agent_api_key FROM email_accounts WHERE id = #{connection.quote(account.id)}"
      )
      expect(raw).not_to eq(account.agent_api_key)
    end

    it "can still be looked up by key (deterministic encryption)" do
      found = EmailAccount.find_by(agent_api_key: account.agent_api_key)
      expect(found).to eq(account)
    end

    it "requires agent_api_key" do
      account.agent_api_key = ""
      expect(account).not_to be_valid
    end

    describe "#regenerate_agent_api_key!" do
      it "swaps in a new key and persists it" do
        original = account.agent_api_key
        account.regenerate_agent_api_key!
        account.reload
        expect(account.agent_api_key).to be_present
        expect(account.agent_api_key).not_to eq(original)
      end
    end
  end

  describe "send window validations" do
    it "defaults to 08:00-22:00" do
      expect(account.send_window_from_hour).to eq(8)
      expect(account.send_window_from_minute).to eq(0)
      expect(account.send_window_to_hour).to eq(22)
      expect(account.send_window_to_minute).to eq(0)
    end

    it "is invalid when end time is before start time" do
      account.send_window_from_hour = 22
      account.send_window_to_hour = 8
      expect(account).not_to be_valid
      expect(account.errors[:base]).to be_present
    end

    it "is invalid when end time equals start time" do
      account.send_window_from_hour = 10
      account.send_window_to_hour = 10
      account.send_window_from_minute = 0
      account.send_window_to_minute = 0
      expect(account).not_to be_valid
    end

    it "validates hour range" do
      account.send_window_from_hour = 25
      expect(account).not_to be_valid
    end

    it "validates minute range" do
      account.send_window_from_minute = 60
      expect(account).not_to be_valid
    end

    it "computes send_window_from in minutes" do
      account.send_window_from_hour = 9
      account.send_window_from_minute = 30
      expect(account.send_window_from).to eq(570)
    end

    it "computes send_window_to in minutes" do
      account.send_window_to_hour = 21
      account.send_window_to_minute = 45
      expect(account.send_window_to).to eq(1305)
    end
  end
end
