require "rails_helper"

RSpec.describe User, type: :model do
  it "creates a valid user" do
    user = build(:user)
    expect(user).to be_valid
  end

  it "generates a UUID id" do
    user = create(:user)
    expect(user.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  it "requires unique email" do
    create(:user, email: "dup@example.com")
    user = build(:user, email: "dup@example.com")
    expect(user).not_to be_valid
    expect(user.errors[:email]).to include("has already been taken")
  end

  it "requires email presence" do
    user = build(:user, email: "")
    expect(user).not_to be_valid
  end

  it "requires valid email format" do
    user = build(:user, email: "notanemail")
    expect(user).not_to be_valid
  end

  it "requires password of at least 6 characters" do
    user = build(:user, password: "12345", password_confirmation: "12345")
    expect(user).not_to be_valid
    expect(user.errors[:password]).to include("is too short (minimum is 6 characters)")
  end

  it "locks the account via lock_access!" do
    user = create(:user)
    expect(user).not_to be_access_locked
    user.lock_access!(send_instructions: false)
    expect(user).to be_access_locked
    expect(user.locked_at).not_to be_nil
  end

  it "unlocks after unlock_in period" do
    user = create(:user)
    user.lock_access!(send_instructions: false)
    expect(user).to be_access_locked

    travel(Devise.unlock_in + 1.minute) do
      expect(user).not_to be_access_locked
    end
  end

  describe "#owned_companies" do
    it "returns only companies where user is owner" do
      user = create(:user)
      owned = user.companies.first # auto-created as owner
      other = create(:company)
      create(:membership, company: other, user: user, role: :member, permissions: %w[dashboard])

      expect(user.owned_companies).to include(owned)
      expect(user.owned_companies).not_to include(other)
    end
  end

  describe "#membership_for" do
    it "returns the membership for a given company" do
      user = create(:user)
      company = user.companies.first
      membership = user.membership_for(company)
      expect(membership).to be_present
      expect(membership.company).to eq(company)
    end

    it "returns nil for unrelated company" do
      user = create(:user)
      other = create(:company)
      expect(user.membership_for(other)).to be_nil
    end
  end

  it "has many email_accounts with dependent destroy" do
    user = create(:user)
    create(:email_account, user: user)
    expect { user.destroy }.to change(EmailAccount, :count).by(-1)
  end
end
