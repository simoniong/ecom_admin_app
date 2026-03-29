require "rails_helper"

RSpec.describe ShopifyStore, type: :model do
  let(:user) { create(:user) }
  let(:store) { create(:shopify_store, user: user, access_token: "shpat_secret") }

  it "is valid with valid attributes" do
    expect(store).to be_valid
  end

  it "generates a UUID id" do
    expect(store.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  it "belongs to user" do
    expect(store.user).to eq(user)
  end

  it "requires shop_domain" do
    store.shop_domain = ""
    expect(store).not_to be_valid
  end

  it "validates shop_domain format" do
    store.shop_domain = "invalid-domain.com"
    expect(store).not_to be_valid
  end

  it "accepts valid myshopify.com domain" do
    store.shop_domain = "my-cool-store.myshopify.com"
    expect(store).to be_valid
  end

  it "enforces shop_domain uniqueness scoped to user" do
    duplicate = build(:shopify_store, user: user, shop_domain: store.shop_domain)
    expect(duplicate).not_to be_valid
  end

  it "allows same domain for different users" do
    other_user = create(:user)
    other_store = build(:shopify_store, user: other_user, shop_domain: store.shop_domain)
    expect(other_store).to be_valid
  end

  it "requires access_token" do
    store.access_token = ""
    expect(store).not_to be_valid
  end

  it "encrypts access_token in database" do
    connection = ActiveRecord::Base.connection
    raw_value = connection.select_value(
      "SELECT access_token FROM shopify_stores WHERE id = #{connection.quote(store.id)}"
    )
    expect(raw_value).not_to eq("shpat_secret")
  end

  describe "associations" do
    it "has many email_accounts" do
      account = create(:email_account, user: user, shopify_store: store)
      expect(store.email_accounts).to include(account)
    end

    it "nullifies email accounts on destroy" do
      account = create(:email_account, user: user, shopify_store: store)
      store.destroy
      expect(account.reload.shopify_store_id).to be_nil
    end
  end
end
