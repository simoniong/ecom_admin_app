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

  it "enforces shop_domain uniqueness for same user" do
    duplicate = build(:shopify_store, user: user, shop_domain: store.shop_domain)
    expect(duplicate).not_to be_valid
  end

  it "enforces global shop_domain uniqueness across users" do
    other_user = create(:user)
    other_store = build(:shopify_store, user: other_user, shop_domain: store.shop_domain)
    expect(other_store).not_to be_valid
    expect(other_store.errors[:shop_domain]).to include("has already been taken")
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

    it "has many ad_accounts" do
      ad_account = create(:ad_account, user: user, shopify_store: store)
      expect(store.ad_accounts).to include(ad_account)
    end

    it "nullifies ad accounts on destroy" do
      ad_account = create(:ad_account, user: user, shopify_store: store)
      store.destroy
      expect(ad_account.reload.shopify_store_id).to be_nil
    end
  end

  describe "credentials" do
    it "requires client_id" do
      store.client_id = nil
      expect(store).not_to be_valid
    end

    it "requires client_secret" do
      store.client_secret = nil
      expect(store).not_to be_valid
    end

    it "encrypts client_secret at rest" do
      store.update!(client_secret: "shpss_plain_value")
      raw = ShopifyStore.connection.select_value(
        "SELECT client_secret FROM shopify_stores WHERE id = '#{store.id}'"
      )
      expect(raw).not_to include("shpss_plain_value")
      expect(store.reload.client_secret).to eq("shpss_plain_value")
    end
  end

  describe ".backfill_credentials_from_env!" do
    around do |example|
      original_id = ENV["SHOPIFY_CLIENT_ID"]
      original_secret = ENV["SHOPIFY_CLIENT_SECRET"]
      example.run
      ENV["SHOPIFY_CLIENT_ID"] = original_id
      ENV["SHOPIFY_CLIENT_SECRET"] = original_secret
    end

    it "fills missing credentials from ENV and encrypts the secret" do
      ENV["SHOPIFY_CLIENT_ID"] = "env-client-id"
      ENV["SHOPIFY_CLIENT_SECRET"] = "env-client-secret"
      store.update_columns(client_id: nil, client_secret: nil)

      ShopifyStore.backfill_credentials_from_env!

      store.reload
      expect(store.client_id).to eq("env-client-id")
      expect(store.client_secret).to eq("env-client-secret")
      raw = ShopifyStore.connection.select_value(
        "SELECT client_secret FROM shopify_stores WHERE id = '#{store.id}'"
      )
      expect(raw).not_to include("env-client-secret")
    end

    it "does not overwrite stores that already have credentials" do
      ENV["SHOPIFY_CLIENT_ID"] = "env-client-id"
      ENV["SHOPIFY_CLIENT_SECRET"] = "env-client-secret"
      store.update!(client_id: "own-id", client_secret: "own-secret")

      ShopifyStore.backfill_credentials_from_env!

      store.reload
      expect(store.client_id).to eq("own-id")
      expect(store.client_secret).to eq("own-secret")
    end

    it "raises when ENV credentials are not set" do
      ENV["SHOPIFY_CLIENT_ID"] = nil
      ENV["SHOPIFY_CLIENT_SECRET"] = nil
      store.update_columns(client_id: nil, client_secret: nil)

      expect { ShopifyStore.backfill_credentials_from_env! }
        .to raise_error(/SHOPIFY_CLIENT_ID/)
    end
  end
end
