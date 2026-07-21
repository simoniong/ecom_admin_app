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

  describe "cost_fx_rate validation" do
    it "accepts nil" do
      store.cost_fx_rate = nil
      expect(store).to be_valid
    end

    it "accepts positive values" do
      store.cost_fx_rate = 7.2
      expect(store).to be_valid
    end

    it "rejects zero" do
      store.cost_fx_rate = 0
      expect(store).not_to be_valid
    end

    it "rejects negative values" do
      store.cost_fx_rate = -1
      expect(store).not_to be_valid
    end
  end

  describe "default_service_type validation" do
    it "accepts nil / blank (no service configured)" do
      store.default_service_type = nil
      expect(store).to be_valid
      store.default_service_type = ""
      expect(store).to be_valid
    end

    it "accepts a canonical service type" do
      store.default_service_type = "with_battery"
      expect(store).to be_valid
    end

    it "rejects a non-canonical service type" do
      store.default_service_type = "standard_with_battery"
      expect(store).not_to be_valid
      expect(store.errors[:default_service_type]).to be_present
    end
  end

  describe "trustpilot_bcc_email" do
    it "is valid when blank" do
      store = build(:shopify_store, trustpilot_bcc_email: nil)
      expect(store).to be_valid
    end

    it "accepts a Trustpilot plus-addressed email" do
      store = build(:shopify_store, trustpilot_bcc_email: "paintkitstudio.com+a43bb38eeb@invite.trustpilot.com")
      expect(store).to be_valid
    end

    it "rejects a malformed address" do
      store = build(:shopify_store, trustpilot_bcc_email: "not-an-email")
      expect(store).not_to be_valid
      expect(store.errors[:trustpilot_bcc_email]).to be_present
    end

    it "rejects a valid email that is not a Trustpilot invite address" do
      store = build(:shopify_store, trustpilot_bcc_email: "someone@example.com")
      expect(store).not_to be_valid
      expect(store.errors[:trustpilot_bcc_email]).to be_present
    end
  end

  describe "#display_name" do
    it "returns the Shopify shop name when present" do
      store.update!(name: "Paint Kit Studio", shop_domain: "paint-kit.myshopify.com")
      expect(store.display_name).to eq("Paint Kit Studio")
    end

    it "falls back to the shop_domain when name is nil" do
      store.update!(name: nil, shop_domain: "paint-kit.myshopify.com")
      expect(store.display_name).to eq("paint-kit.myshopify.com")
    end

    it "falls back to the shop_domain when name is an empty string" do
      store.update!(name: "", shop_domain: "paint-kit.myshopify.com")
      expect(store.display_name).to eq("paint-kit.myshopify.com")
    end
  end

  describe "packing settings" do
    let(:store) { create(:shopify_store) }

    it "defaults packing_enabled to false" do
      expect(store.packing_enabled).to be(false)
    end

    it "requires prefix and start number when enabling packing" do
      store.packing_enabled = true
      expect(store).not_to be_valid
      expect(store.errors[:package_prefix]).to be_present
      expect(store.errors[:package_number_start]).to be_present
    end

    it "is valid when enabling with prefix and start" do
      store.assign_attributes(packing_enabled: true, package_prefix: "XMBDE", package_number_start: 2013094)
      expect(store).to be_valid
    end

    it "locks prefix/start once a package exists" do
      store.update!(packing_enabled: true, package_prefix: "XMBDE", package_number_start: 2013094)
      create(:package, shopify_store: store)
      store.reload.package_prefix = "OTHER"
      expect(store).not_to be_valid
      expect(store.errors[:package_prefix]).to be_present
    end

    it "does not lock other fields once a package exists" do
      store.update!(packing_enabled: true, package_prefix: "XMBDE", package_number_start: 1)
      create(:package, shopify_store: store)
      store.reload.name = "Renamed"
      expect(store).to be_valid
    end
  end

  describe "#short_name" do
    it "returns the Shopify shop name when present" do
      store.update!(name: "Paint Kit Studio", shop_domain: "paint-kit.myshopify.com")
      expect(store.short_name).to eq("Paint Kit Studio")
    end

    it "strips the .myshopify.com suffix when name is nil" do
      store.update!(name: nil, shop_domain: "paint-kit.myshopify.com")
      expect(store.short_name).to eq("paint-kit")
    end

    it "strips the .myshopify.com suffix when name is an empty string" do
      store.update!(name: "", shop_domain: "paint-kit.myshopify.com")
      expect(store.short_name).to eq("paint-kit")
    end
  end
end
