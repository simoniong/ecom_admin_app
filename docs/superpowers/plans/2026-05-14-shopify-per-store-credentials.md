# Shopify Per-Store Credentials Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Shopify `client_id` / `client_secret` from a single global ENV-based app to per-store columns on `ShopifyStore`, so each merchant connects with their own custom-distribution app's credentials.

**Architecture:** Add encrypted per-store credential columns; the migration backfills existing stores from the current global ENV via a model class method. `ShopifyOauthController` takes credentials from the connect form, stashes them in the session for the OAuth round-trip, and writes them onto the store on callback. `ShopifyWebhooksController` verifies HMAC with the per-store secret, looked up by the shop-domain header. The connect-store UI becomes a single three-field form with a merchant setup guide.

**Tech Stack:** Rails 8.1, PostgreSQL (UUIDs), Active Record Encryption, RSpec + FactoryBot, WebMock, Hotwire/Turbo, Tailwind.

**Branch:** `feature/shopify-per-store-credentials` (already cut from `origin/staging`).

**Spec:** `docs/superpowers/specs/2026-05-14-shopify-per-store-credentials-design.md`.

---

## File Structure

| File | Responsibility |
|---|---|
| `db/migrate/20260514000001_add_credentials_to_shopify_stores.rb` | Add `client_id` + `client_secret` columns; trigger backfill |
| `app/models/shopify_store.rb` | Encrypt `client_secret`, validate presence, `backfill_credentials_from_env!` class method |
| `spec/factories/shopify_stores.rb` | Default `client_id` / `client_secret` for the factory |
| `app/controllers/shopify_oauth_controller.rb` | `#auth` reads form credentials + stashes in session; `#callback` reads session; private helpers take credential args |
| `app/controllers/shopify_webhooks_controller.rb` | Per-store HMAC verification via `@webhook_store` |
| `app/views/shopify_stores/index.html.erb` | Single three-field connect form + collapsible merchant guide |
| `config/locales/{en,zh-TW,zh-CN}.yml` | Connect-form labels, guide text; remove dead keys |
| `spec/models/shopify_store_spec.rb` | Validation, encryption, backfill method tests |
| `spec/requests/shopify_oauth_spec.rb` | Full rewrite — per-store credential flow |
| `spec/requests/shopify_webhooks_spec.rb` | Full rewrite — per-store HMAC |
| `spec/system/shopify_stores_spec.rb` | New — connect form renders and submits |

---

## Task 1: Model — encryption, validation, backfill method

**Files:**
- Modify: `app/models/shopify_store.rb`
- Test: `spec/models/shopify_store_spec.rb`

- [ ] **Step 1: Write the failing tests**

Append inside the `RSpec.describe ShopifyStore, type: :model do` block in `spec/models/shopify_store_spec.rb`, before its closing `end`:

```ruby
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
```

Note: these tests reference `client_id` / `client_secret` columns that do not exist yet. They will error until Task 2's migration runs. That is expected — this is the red phase; Task 2 makes the columns exist and Step 3 below makes the logic pass.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/models/shopify_store_spec.rb -e credentials -e backfill_credentials_from_env`
Expected: FAIL — `NoMethodError: unknown attribute 'client_id'` (columns not added yet) or validation/method missing.

- [ ] **Step 3: Implement the model changes**

Replace the full contents of `app/models/shopify_store.rb` with:

```ruby
class ShopifyStore < ApplicationRecord
  include GroupAssignable

  belongs_to :user
  belongs_to :company
  has_many :email_accounts, dependent: :nullify
  has_many :ad_accounts, dependent: :nullify
  has_many :customers, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :email_workflows, dependent: :destroy

  encrypts :access_token, deterministic: false
  encrypts :client_secret, deterministic: false

  validates :shop_domain, presence: true, uniqueness: true,
            format: { with: /\A[\w-]+\.myshopify\.com\z/, message: "must be a valid myshopify.com domain" }
  validates :access_token, presence: true
  validates :client_id, presence: true
  validates :client_secret, presence: true

  # One-time backfill invoked by the add_credentials_to_shopify_stores migration.
  # Copies the legacy global app credentials onto any store still missing them.
  # Must run through the model (not update_all) so client_secret is encrypted.
  def self.backfill_credentials_from_env!
    client_id = ENV["SHOPIFY_CLIENT_ID"]
    client_secret = ENV["SHOPIFY_CLIENT_SECRET"]

    if client_id.blank? || client_secret.blank?
      raise "backfill_credentials_from_env!: SHOPIFY_CLIENT_ID / SHOPIFY_CLIENT_SECRET must be set"
    end

    where(client_id: nil).or(where(client_secret: nil)).find_each do |store|
      store.update!(client_id: client_id, client_secret: client_secret)
    end
  end

  def active_timezone
    ActiveSupport::TimeZone[timezone] || ActiveSupport::TimeZone["UTC"]
  end
end
```

- [ ] **Step 4: Defer test run to Task 2**

These tests cannot pass until the migration in Task 2 adds the columns. Do not run them yet. Proceed to Task 2; Task 2 Step 4 runs this file's tests.

- [ ] **Step 5: Commit**

```bash
git add app/models/shopify_store.rb spec/models/shopify_store_spec.rb
git commit -m "feat: per-store credential encryption, validation, and ENV backfill on ShopifyStore"
```

---

## Task 2: Migration — add columns and backfill

**Files:**
- Create: `db/migrate/20260514000001_add_credentials_to_shopify_stores.rb`

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260514000001_add_credentials_to_shopify_stores.rb`:

```ruby
class AddCredentialsToShopifyStores < ActiveRecord::Migration[8.1]
  def up
    add_column :shopify_stores, :client_id, :string
    add_column :shopify_stores, :client_secret, :text

    ShopifyStore.reset_column_information
    ShopifyStore.backfill_credentials_from_env!
  end

  def down
    remove_column :shopify_stores, :client_secret
    remove_column :shopify_stores, :client_id
  end
end
```

- [ ] **Step 2: Run the migration**

First ensure the legacy ENV vars are present in your shell (the migration backfills from them):

Run: `SHOPIFY_CLIENT_ID=dev-client-id SHOPIFY_CLIENT_SECRET=dev-client-secret bin/rails db:migrate`
Expected: `add_column(:shopify_stores, :client_id, ...)`, `add_column(:shopify_stores, :client_secret, ...)`, then `Migrated`. If the dev DB has existing `shopify_stores` rows they are backfilled; if empty, the backfill is a no-op.

- [ ] **Step 3: Prepare the test DB**

Run: `bin/rails db:test:prepare`
Expected: silent success.

- [ ] **Step 4: Run Task 1's model tests (now that columns exist)**

Run: `bundle exec rspec spec/models/shopify_store_spec.rb`
Expected: all green, including the `credentials` and `.backfill_credentials_from_env!` examples from Task 1.

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20260514000001_add_credentials_to_shopify_stores.rb db/schema.rb
git commit -m "feat: add client_id/client_secret columns to shopify_stores with ENV backfill"
```

---

## Task 3: Factory — default credentials

**Files:**
- Modify: `spec/factories/shopify_stores.rb`

- [ ] **Step 1: Update the factory**

Replace the contents of `spec/factories/shopify_stores.rb` with:

```ruby
FactoryBot.define do
  factory :shopify_store do
    user
    company { user&.companies&.first || association(:company) }
    sequence(:shop_domain) { |n| "test-store-#{n}.myshopify.com" }
    access_token { "shpat_test_token" }
    client_id { "test-client-id" }
    client_secret { "shpss_test_client_secret" }
    scopes { "read_products,read_customers,read_all_orders,read_fulfillments,read_analytics" }
    installed_at { Time.current }

    trait :with_group do
      after(:build) do |store|
        store.group ||= create(:group, company: store.company)
      end
    end
  end
end
```

- [ ] **Step 2: Verify the factory still builds a valid record**

Run: `bundle exec rspec spec/models/shopify_store_spec.rb -e "is valid with valid attributes"`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add spec/factories/shopify_stores.rb
git commit -m "test: add default client_id/client_secret to shopify_store factory"
```

---

## Task 4: ShopifyOauthController — `#auth` reads form credentials, stashes in session

**Files:**
- Modify: `app/controllers/shopify_oauth_controller.rb`
- Test: `spec/requests/shopify_oauth_spec.rb` (rewritten in full in Task 5; this task adds the `#auth` portion)

This task and Task 5 together rewrite `spec/requests/shopify_oauth_spec.rb`. To keep each task self-contained, Task 4 writes the **complete new spec file** (both `#auth` and `#callback` describe blocks). The `#callback` examples will fail until Task 5 implements `#callback`; that is the expected red phase between Task 4 and Task 5.

- [ ] **Step 1: Write the complete new request spec**

Replace the full contents of `spec/requests/shopify_oauth_spec.rb` with:

```ruby
require "rails_helper"

RSpec.describe "ShopifyOauth", type: :request do
  let(:user) { create(:user) }
  let(:client_id) { "merchant-client-id" }
  let(:client_secret) { "merchant-client-secret" }

  def auth_params(extra = {})
    { shop: "test.myshopify.com", client_id: client_id, client_secret: client_secret }.merge(extra)
  end

  describe "GET /shopify/auth" do
    it "redirects unauthenticated user" do
      get shopify_auth_path, params: auth_params
      expect(response).to redirect_to(new_user_session_path)
    end

    it "redirects to the Shopify authorize URL using the submitted client_id" do
      sign_in user
      get shopify_auth_path, params: auth_params
      expect(response).to have_http_status(:redirect)
      expect(response.location).to include("test.myshopify.com/admin/oauth/authorize")
      expect(response.location).to include("merchant-client-id")
    end

    it "stashes the nonce and pending credentials in the session" do
      sign_in user
      get shopify_auth_path, params: auth_params
      expect(session[:shopify_oauth_nonce]).to be_present
      expect(session[:shopify_pending_client_id]).to eq(client_id)
      expect(session[:shopify_pending_client_secret]).to eq(client_secret)
      expect(session[:shopify_pending_shop]).to eq("test.myshopify.com")
    end

    it "rejects an invalid shop domain" do
      sign_in user
      get shopify_auth_path, params: auth_params(shop: "invalid-domain.com")
      expect(response).to redirect_to(shopify_stores_path)
    end

    it "rejects a blank shop domain" do
      sign_in user
      get shopify_auth_path, params: auth_params(shop: "")
      expect(response).to redirect_to(shopify_stores_path)
    end

    it "rejects a missing client_id" do
      sign_in user
      get shopify_auth_path, params: auth_params(client_id: "")
      expect(response).to redirect_to(shopify_stores_path)
      expect(flash[:alert]).to be_present
    end

    it "rejects a missing client_secret" do
      sign_in user
      get shopify_auth_path, params: auth_params(client_secret: "")
      expect(response).to redirect_to(shopify_stores_path)
      expect(flash[:alert]).to be_present
    end

    context "when the company has groups" do
      let(:company) { user.companies.first }
      let!(:group) { create(:group, company: company, name: "Sales") }

      before { sign_in user }

      it "redirects with an alert when owner omits group_id" do
        get shopify_auth_path, params: auth_params
        expect(response).to redirect_to(shopify_stores_path)
        expect(flash[:alert]).to be_present
      end

      it "stores pending_binding_group_id when owner supplies group_id" do
        get shopify_auth_path, params: auth_params(group_id: group.id)
        expect(response.location).to include("test.myshopify.com/admin/oauth/authorize")
        expect(session[:pending_binding_group_id]).to eq(group.id)
      end
    end
  end

  describe "GET /shopify/callback" do
    before { sign_in user }

    # Drives #auth to populate the session the way the real flow does.
    def start_auth(extra = {})
      get shopify_auth_path, params: auth_params(extra)
      session[:shopify_oauth_nonce]
    end

    def signed_callback_params(nonce:, shop: "test.myshopify.com", code: "test-code")
      params = { "code" => code, "shop" => shop, "state" => nonce }
      message = params.sort.map { |k, v| "#{k}=#{v}" }.join("&")
      hmac = OpenSSL::HMAC.hexdigest("SHA256", client_secret, message)
      params.merge("hmac" => hmac)
    end

    def stub_token_and_timezone
      stub_request(:post, "https://test.myshopify.com/admin/oauth/access_token")
        .to_return(
          status: 200,
          body: { access_token: "shpat_new_token", scope: "read_products,read_customers" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
      stub_request(:get, %r{test\.myshopify\.com/admin/api/2024-10/shop\.json})
        .to_return(
          status: 200,
          body: { shop: { iana_timezone: "Asia/Macau" } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "rejects a missing code" do
      nonce = start_auth
      get shopify_callback_path, params: { shop: "test.myshopify.com", state: nonce }
      expect(response).to redirect_to(shopify_stores_path)
    end

    it "rejects an invalid shop domain" do
      nonce = start_auth
      get shopify_callback_path, params: { shop: "bad.com", code: "code", state: nonce }
      expect(response).to redirect_to(shopify_stores_path)
    end

    it "redirects with oauth_failure when the session has no pending credentials" do
      # No start_auth call — session is empty
      get shopify_callback_path, params: { shop: "test.myshopify.com", code: "test-code", state: "nonce" }
      expect(response).to redirect_to(shopify_stores_path)
      expect(flash[:alert]).to eq(I18n.t("shopify_stores.oauth_failure"))
    end

    it "redirects with an alert when the callback shop differs from the session shop" do
      nonce = start_auth
      params = signed_callback_params(nonce: nonce, shop: "other.myshopify.com")
      get shopify_callback_path, params: params
      expect(response).to redirect_to(shopify_stores_path)
      expect(flash[:alert]).to be_present
    end

    it "rejects a state mismatch" do
      start_auth
      get shopify_callback_path, params: {
        shop: "test.myshopify.com", code: "test-code", state: "wrong-state", hmac: "abc"
      }
      expect(response).to redirect_to(shopify_stores_path)
      expect(flash[:alert]).to eq(I18n.t("shopify_stores.oauth_failure"))
    end

    it "creates the store with the submitted credentials on a successful callback" do
      nonce = start_auth
      stub_token_and_timezone

      expect {
        get shopify_callback_path, params: signed_callback_params(nonce: nonce)
      }.to change(ShopifyStore, :count).by(1)

      store = user.shopify_stores.last
      expect(store.shop_domain).to eq("test.myshopify.com")
      expect(store.access_token).to eq("shpat_new_token")
      expect(store.client_id).to eq(client_id)
      expect(store.client_secret).to eq(client_secret)
      expect(response).to redirect_to(shopify_stores_path)
      expect(flash[:notice]).to eq(I18n.t("shopify_stores.bind_success"))
    end

    it "clears the pending session values after a successful callback" do
      nonce = start_auth
      stub_token_and_timezone
      get shopify_callback_path, params: signed_callback_params(nonce: nonce)
      expect(session[:shopify_pending_client_id]).to be_nil
      expect(session[:shopify_pending_client_secret]).to be_nil
      expect(session[:shopify_pending_shop]).to be_nil
    end

    it "enqueues sync jobs after a successful store creation" do
      nonce = start_auth
      stub_token_and_timezone

      expect {
        get shopify_callback_path, params: signed_callback_params(nonce: nonce)
      }.to have_enqueued_job(SyncAllShopifyOrdersJob)
        .and have_enqueued_job(RegisterShopifyWebhooksJob)
        .and have_enqueued_job(BackfillShopifyMetricsJob)
    end

    it "redirects on a failed token exchange" do
      nonce = start_auth
      stub_request(:post, "https://test.myshopify.com/admin/oauth/access_token")
        .to_return(status: 400, body: "Bad Request")

      get shopify_callback_path, params: signed_callback_params(nonce: nonce)
      expect(response).to redirect_to(shopify_stores_path)
      expect(flash[:alert]).to eq(I18n.t("shopify_stores.bind_failure"))
    end

    it "shows already_bound when the store is bound by another user" do
      other_user = create(:user)
      create(:shopify_store, user: other_user, shop_domain: "test.myshopify.com")
      nonce = start_auth
      stub_token_and_timezone

      get shopify_callback_path, params: signed_callback_params(nonce: nonce)
      expect(response).to redirect_to(shopify_stores_path)
      expect(flash[:alert]).to eq(I18n.t("shopify_stores.already_bound"))
    end
  end
end
```

- [ ] **Step 2: Run the `#auth` examples to verify they fail**

Run: `bundle exec rspec spec/requests/shopify_oauth_spec.rb -e "GET /shopify/auth"`
Expected: FAIL — controller still reads `ENV["SHOPIFY_CLIENT_ID"]` and does not stash credentials in the session.

- [ ] **Step 3: Implement the `#auth` action**

In `app/controllers/shopify_oauth_controller.rb`, replace the `auth` method (lines 4-44) with:

```ruby
  def auth
    shop = params[:shop].to_s.strip.downcase
    client_id = params[:client_id].to_s.strip
    client_secret = params[:client_secret].to_s.strip

    unless shop.match?(SHOP_DOMAIN_FORMAT)
      redirect_to shopify_stores_path, alert: t("shopify_stores.oauth_failure")
      return
    end

    if client_id.blank? || client_secret.blank?
      redirect_to shopify_stores_path, alert: t("shopify_stores.credentials_required")
      return
    end

    if company_has_groups?
      group = resolve_binding_group(params[:group_id])
      if group.nil?
        redirect_to shopify_stores_path, alert: t("shopify_stores.group_required")
        return
      end
      session[:pending_binding_group_id] = group.id
    else
      session.delete(:pending_binding_group_id)
    end

    nonce = SecureRandom.hex(16)
    session[:shopify_oauth_nonce] = nonce
    session[:shopify_pending_client_id] = client_id
    session[:shopify_pending_client_secret] = client_secret
    session[:shopify_pending_shop] = shop

    scopes = "read_products,read_customers,read_all_orders,read_fulfillments,read_analytics,write_webhooks"
    redirect_uri = shopify_callback_url(locale: nil)

    authorize_url = "https://#{shop}/admin/oauth/authorize?" + {
      client_id: client_id,
      scope: scopes,
      redirect_uri: redirect_uri,
      state: nonce
    }.to_query

    redirect_to authorize_url, allow_other_host: true
  end
```

- [ ] **Step 4: Run the `#auth` examples to verify they pass**

Run: `bundle exec rspec spec/requests/shopify_oauth_spec.rb -e "GET /shopify/auth"`
Expected: all `GET /shopify/auth` examples PASS. The `GET /shopify/callback` examples still FAIL — that is expected and fixed in Task 5.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/shopify_oauth_controller.rb spec/requests/shopify_oauth_spec.rb
git commit -m "feat: ShopifyOauthController#auth takes per-store credentials from the connect form"
```

---

## Task 5: ShopifyOauthController — `#callback` reads session credentials

**Files:**
- Modify: `app/controllers/shopify_oauth_controller.rb`

- [ ] **Step 1: Confirm the callback examples currently fail**

Run: `bundle exec rspec spec/requests/shopify_oauth_spec.rb -e "GET /shopify/callback"`
Expected: FAIL — `#callback` still reads ENV and does not consume the session pending values.

- [ ] **Step 2: Implement the `#callback` action and private helpers**

In `app/controllers/shopify_oauth_controller.rb`, replace everything from the `def callback` line through the end of the file (the `callback` method, the `private` keyword, and all private helpers) with the block below. The block reproduces `fetch_shop_timezone` unchanged and contains exactly one `private` keyword:

```ruby
  def callback
    shop = params[:shop].to_s.strip.downcase
    code = params[:code]
    state = params[:state]
    hmac = params[:hmac]

    client_id = session[:shopify_pending_client_id]
    client_secret = session[:shopify_pending_client_secret]
    pending_shop = session[:shopify_pending_shop]

    if client_id.blank? || client_secret.blank? || pending_shop.blank?
      clear_pending_session
      redirect_to shopify_stores_path, alert: t("shopify_stores.oauth_failure")
      return
    end

    unless shop.match?(SHOP_DOMAIN_FORMAT) && code.present?
      redirect_to shopify_stores_path, alert: t("shopify_stores.oauth_failure")
      return
    end

    unless shop == pending_shop
      clear_pending_session
      redirect_to shopify_stores_path, alert: t("shopify_stores.oauth_failure")
      return
    end

    session_nonce = session.delete(:shopify_oauth_nonce).to_s
    if session_nonce.present?
      unless state.present? && ActiveSupport::SecurityUtils.secure_compare(state.to_s, session_nonce)
        redirect_to shopify_stores_path, alert: t("shopify_stores.oauth_failure")
        return
      end
    end

    unless verify_hmac(hmac, request.query_parameters.except("hmac"), client_secret)
      redirect_to shopify_stores_path, alert: t("shopify_stores.oauth_failure")
      return
    end

    access_token_response = exchange_code_for_token(shop, code, client_id, client_secret)

    unless access_token_response
      clear_pending_session
      redirect_to shopify_stores_path, alert: t("shopify_stores.bind_failure")
      return
    end

    store = current_company.shopify_stores.find_or_initialize_by(shop_domain: shop)
    store.user = current_user
    if store.new_record? && (pending_group_id = session.delete(:pending_binding_group_id)).present?
      store.group_id = pending_group_id
    end
    store.assign_attributes(
      access_token: access_token_response["access_token"],
      client_id: client_id,
      client_secret: client_secret,
      scopes: access_token_response["scope"],
      timezone: fetch_shop_timezone(shop, access_token_response["access_token"]),
      installed_at: store.installed_at || Time.current
    )

    clear_pending_session

    if store.save
      SyncAllShopifyOrdersJob.perform_later(store.id)
      RegisterShopifyWebhooksJob.perform_later(store.id)
      BackfillShopifyMetricsJob.perform_later(store.id)
      redirect_to shopify_stores_path, notice: t("shopify_stores.bind_success")
    else
      alert = store.errors[:shop_domain].any? ? t("shopify_stores.already_bound") : t("shopify_stores.bind_failure")
      redirect_to shopify_stores_path, alert: alert
    end
  end

  private

  def clear_pending_session
    session.delete(:shopify_pending_client_id)
    session.delete(:shopify_pending_client_secret)
    session.delete(:shopify_pending_shop)
  end

  def verify_hmac(hmac, query_params, client_secret)
    return false if hmac.blank? || client_secret.blank?

    message = query_params.sort.map { |k, v| "#{k}=#{v}" }.join("&")
    digest = OpenSSL::HMAC.hexdigest("SHA256", client_secret, message)
    return false unless hmac.bytesize == digest.bytesize

    ActiveSupport::SecurityUtils.secure_compare(digest, hmac)
  end

  def fetch_shop_timezone(shop, access_token)
    response = HTTParty.get(
      "https://#{shop}/admin/api/2024-10/shop.json",
      query: { fields: "iana_timezone" },
      headers: { "X-Shopify-Access-Token" => access_token, "Content-Type" => "application/json" }
    )
    return "UTC" unless response.success?
    response.parsed_response.dig("shop", "iana_timezone") || "UTC"
  rescue
    "UTC"
  end

  def exchange_code_for_token(shop, code, client_id, client_secret)
    response = HTTParty.post(
      "https://#{shop}/admin/oauth/access_token",
      body: {
        client_id: client_id,
        client_secret: client_secret,
        code: code
      }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    return nil unless response.success?

    response.parsed_response
  end
```

Note: the `private` keyword appears once. If the file already has a `private` line from the original, ensure the replacement keeps exactly one `private` and that `fetch_shop_timezone` is included (it is, above, unchanged from the original).

- [ ] **Step 3: Run the full oauth spec to verify it passes**

Run: `bundle exec rspec spec/requests/shopify_oauth_spec.rb`
Expected: all examples (both `#auth` and `#callback`) PASS.

- [ ] **Step 4: Commit**

```bash
git add app/controllers/shopify_oauth_controller.rb
git commit -m "feat: ShopifyOauthController#callback consumes per-store credentials from the session"
```

---

## Task 6: ShopifyWebhooksController — per-store HMAC verification

**Files:**
- Modify: `app/controllers/shopify_webhooks_controller.rb`
- Test: `spec/requests/shopify_webhooks_spec.rb`

- [ ] **Step 1: Write the complete new webhook request spec**

Replace the full contents of `spec/requests/shopify_webhooks_spec.rb` with:

```ruby
require "rails_helper"

RSpec.describe "ShopifyWebhooks", type: :request do
  let(:store) { create(:shopify_store) }
  let(:order_payload) do
    {
      id: 12345, name: "#1001", email: "buyer@example.com",
      total_price: "49.99", currency: "USD",
      financial_status: "paid", fulfillment_status: "fulfilled",
      created_at: "2026-03-20",
      customer: { id: 100, email: "buyer@example.com", first_name: "Jane" },
      fulfillments: []
    }.to_json
  end

  def webhook_hmac(body, secret)
    Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", secret, body))
  end

  def post_webhook(body:, secret:, topic: "orders/create", shop_domain: store.shop_domain, hmac: nil)
    hmac ||= webhook_hmac(body, secret)
    post "/shopify/webhooks", params: body, headers: {
      "Content-Type" => "application/json",
      "X-Shopify-Topic" => topic,
      "X-Shopify-Shop-Domain" => shop_domain,
      "X-Shopify-Hmac-Sha256" => hmac
    }
  end

  describe "POST /shopify/webhooks" do
    it "verifies HMAC with the store's own client_secret and enqueues for orders/create" do
      expect {
        post_webhook(body: order_payload, secret: store.client_secret, topic: "orders/create")
      }.to have_enqueued_job(ProcessShopifyOrderWebhookJob).with(store.id, anything)

      expect(response).to have_http_status(:ok)
    end

    it "enqueues for orders/updated" do
      expect {
        post_webhook(body: order_payload, secret: store.client_secret, topic: "orders/updated")
      }.to have_enqueued_job(ProcessShopifyOrderWebhookJob)

      expect(response).to have_http_status(:ok)
    end

    it "returns 200 for an unknown topic without enqueuing" do
      expect {
        post_webhook(body: order_payload, secret: store.client_secret, topic: "products/create")
      }.not_to have_enqueued_job(ProcessShopifyOrderWebhookJob)

      expect(response).to have_http_status(:ok)
    end

    it "returns 401 when the HMAC does not match the store's client_secret" do
      post_webhook(body: order_payload, secret: "wrong-secret", topic: "orders/create")
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 when the HMAC header is missing" do
      post "/shopify/webhooks", params: order_payload, headers: {
        "Content-Type" => "application/json",
        "X-Shopify-Topic" => "orders/create",
        "X-Shopify-Shop-Domain" => store.shop_domain
      }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 404 for an unknown shop domain on a non-GDPR topic" do
      expect {
        post_webhook(body: order_payload, secret: "any-secret",
                     topic: "orders/create", shop_domain: "unknown.myshopify.com")
      }.not_to have_enqueued_job(ProcessShopifyOrderWebhookJob)

      expect(response).to have_http_status(:not_found)
    end

    context "GDPR mandatory webhooks" do
      let(:redact_payload) do
        {
          shop_id: 999,
          shop_domain: store.shop_domain,
          customer: { id: 5001, email: "privacy@example.com" },
          orders_to_redact: []
        }.to_json
      end

      it "returns 200 for customers/data_request without enqueuing" do
        expect {
          post_webhook(body: redact_payload, secret: store.client_secret, topic: "customers/data_request")
        }.not_to have_enqueued_job

        expect(response).to have_http_status(:ok)
      end

      it "enqueues ProcessCustomerRedactJob for customers/redact on a known store" do
        expect {
          post_webhook(body: redact_payload, secret: store.client_secret, topic: "customers/redact")
        }.to have_enqueued_job(ProcessCustomerRedactJob).with(store.id, anything)

        expect(response).to have_http_status(:ok)
      end

      it "enqueues ProcessShopRedactJob for shop/redact on a known store" do
        expect {
          post_webhook(body: redact_payload, secret: store.client_secret, topic: "shop/redact")
        }.to have_enqueued_job(ProcessShopRedactJob).with(store.id)

        expect(response).to have_http_status(:ok)
      end

      it "returns 200 for shop/redact for an unknown shop and skips HMAC" do
        expect {
          post_webhook(body: redact_payload, secret: "any-secret",
                       topic: "shop/redact", shop_domain: "gone.myshopify.com")
        }.not_to have_enqueued_job(ProcessShopRedactJob)

        expect(response).to have_http_status(:ok)
      end

      it "returns 200 for customers/redact for an unknown shop and skips HMAC" do
        expect {
          post_webhook(body: redact_payload, secret: "any-secret",
                       topic: "customers/redact", shop_domain: "gone.myshopify.com")
        }.not_to have_enqueued_job(ProcessCustomerRedactJob)

        expect(response).to have_http_status(:ok)
      end

      it "returns 401 for a known store when the HMAC is invalid on a GDPR topic" do
        post_webhook(body: redact_payload, secret: "wrong-secret", topic: "customers/redact")
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
```

- [ ] **Step 2: Run the webhook spec to verify it fails**

Run: `bundle exec rspec spec/requests/shopify_webhooks_spec.rb`
Expected: FAIL — controller still verifies HMAC with the global `ENV["SHOPIFY_CLIENT_SECRET"]`.

- [ ] **Step 3: Implement the controller changes**

Replace the full contents of `app/controllers/shopify_webhooks_controller.rb` with:

```ruby
class ShopifyWebhooksController < ActionController::API
  before_action :verify_shopify_webhook

  def receive
    topic = request.headers["X-Shopify-Topic"]
    shop_domain = request.headers["X-Shopify-Shop-Domain"]

    # GDPR compliance webhooks must always return 200, even if the store is unknown
    # (e.g., already uninstalled/deleted). Otherwise Shopify retries indefinitely.
    case topic
    when "customers/data_request"
      customer_id = webhook_payload.dig("customer", "id")
      orders_count = Array(webhook_payload["orders_requested"]).size
      Rails.logger.info("[ShopifyWebhook] customers/data_request shop=#{shop_domain} customer_id=#{customer_id} orders_requested=#{orders_count}")
      head :ok
      return
    when "customers/redact"
      if @webhook_store
        ProcessCustomerRedactJob.perform_later(@webhook_store.id, webhook_payload)
      else
        Rails.logger.info("[ShopifyWebhook] customers/redact for unknown shop=#{shop_domain}")
      end
      head :ok
      return
    when "shop/redact"
      if @webhook_store
        ProcessShopRedactJob.perform_later(@webhook_store.id)
      else
        Rails.logger.info("[ShopifyWebhook] shop/redact for unknown shop=#{shop_domain}")
      end
      head :ok
      return
    end

    unless @webhook_store
      Rails.logger.warn("[ShopifyWebhook] Unknown shop: #{shop_domain}")
      head :not_found
      return
    end

    case topic
    when "orders/create", "orders/updated"
      ProcessShopifyOrderWebhookJob.perform_later(@webhook_store.id, webhook_payload)
    else
      Rails.logger.info("[ShopifyWebhook] Ignoring topic: #{topic}")
    end

    head :ok
  end

  private

  # Looks up the store by the shop-domain header and verifies the webhook HMAC
  # with that store's client_secret. The header is attacker-controllable, but a
  # forged shop name will not match that store's secret, so selecting the secret
  # by header is safe. An unknown shop has no actionable target, so HMAC is
  # skipped and #receive decides the response (200 for GDPR, 404 otherwise).
  def verify_shopify_webhook
    shop_domain = request.headers["X-Shopify-Shop-Domain"]
    @webhook_store = ShopifyStore.find_by(shop_domain: shop_domain)
    return if @webhook_store.nil?

    secret = @webhook_store.client_secret
    if secret.blank?
      Rails.logger.error("[ShopifyWebhook] Store #{shop_domain} has no client_secret")
      head :unauthorized
      return
    end

    request.body.rewind
    body = request.body.read
    request.body.rewind

    digest = OpenSSL::HMAC.digest("SHA256", secret, body)
    computed_hmac = Base64.strict_encode64(digest)
    header_hmac = request.headers["X-Shopify-Hmac-Sha256"]

    unless header_hmac.present? && ActiveSupport::SecurityUtils.secure_compare(computed_hmac, header_hmac)
      head :unauthorized
    end
  end

  def webhook_payload
    @webhook_payload ||= JSON.parse(request.body.tap(&:rewind).read)
  end
end
```

- [ ] **Step 4: Run the webhook spec to verify it passes**

Run: `bundle exec rspec spec/requests/shopify_webhooks_spec.rb`
Expected: all examples PASS.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/shopify_webhooks_controller.rb spec/requests/shopify_webhooks_spec.rb
git commit -m "feat: verify Shopify webhook HMAC with per-store client_secret"
```

---

## Task 7: View + i18n — single connect form with merchant guide

**Files:**
- Modify: `app/views/shopify_stores/index.html.erb`
- Modify: `config/locales/en.yml`
- Modify: `config/locales/zh-TW.yml`
- Modify: `config/locales/zh-CN.yml`

- [ ] **Step 1: Update the English locale**

In `config/locales/en.yml`, within the `shopify_stores:` block, remove these keys: `first_install_title`, `first_install_description`, `reauth_title`, `reauth_description`, `reauth_button`. Then add the following keys to the `shopify_stores:` block (place them after `connect:`):

```yaml
    credentials_required: "Please enter both the Client ID and Client Secret."
    connect_title: "Connect a Shopify store"
    connect_description: "Enter your store's custom app credentials below. Both first-time connection and re-authorization use this form."
    client_id_label: "Client ID"
    client_secret_label: "Client Secret"
    guide_summary: "How to create your custom app and get these credentials"
    guide_step_1: "In your Shopify dev dashboard, create a new app."
    guide_step_2_html: "Set the Allowed redirection URL to: <code>%{callback_url}</code>"
    guide_step_3: "Set the API scopes to: read_products, read_customers, read_all_orders, read_fulfillments, read_analytics, write_webhooks"
    guide_step_4: "Choose Custom distribution and target your own store."
    guide_step_5: "Copy the Client ID and Client Secret into the form below."
```

- [ ] **Step 2: Update the Traditional Chinese locale**

In `config/locales/zh-TW.yml`, within the `shopify_stores:` block, remove the same five keys (`first_install_title`, `first_install_description`, `reauth_title`, `reauth_description`, `reauth_button`) and add:

```yaml
    credentials_required: "請輸入 Client ID 與 Client Secret。"
    connect_title: "連接 Shopify 店家"
    connect_description: "在下方填入你店家自訂 app 的憑證。首次連接與重新授權都用這個表單。"
    client_id_label: "Client ID"
    client_secret_label: "Client Secret"
    guide_summary: "如何建立自訂 app 並取得這些憑證"
    guide_step_1: "在你的 Shopify dev dashboard 建立一個新 app。"
    guide_step_2_html: "把 Allowed redirection URL 設為：<code>%{callback_url}</code>"
    guide_step_3: "把 API scopes 設為：read_products, read_customers, read_all_orders, read_fulfillments, read_analytics, write_webhooks"
    guide_step_4: "選擇 Custom distribution，目標選你自己的店。"
    guide_step_5: "把 Client ID 與 Client Secret 複製到下方表單。"
```

- [ ] **Step 3: Update the Simplified Chinese locale**

In `config/locales/zh-CN.yml`, within the `shopify_stores:` block, remove the same five keys and add:

```yaml
    credentials_required: "请输入 Client ID 与 Client Secret。"
    connect_title: "连接 Shopify 店铺"
    connect_description: "在下方填入你店铺自定义 app 的凭证。首次连接与重新授权都用这个表单。"
    client_id_label: "Client ID"
    client_secret_label: "Client Secret"
    guide_summary: "如何创建自定义 app 并获取这些凭证"
    guide_step_1: "在你的 Shopify dev dashboard 创建一个新 app。"
    guide_step_2_html: "把 Allowed redirection URL 设为：<code>%{callback_url}</code>"
    guide_step_3: "把 API scopes 设为：read_products, read_customers, read_all_orders, read_fulfillments, read_analytics, write_webhooks"
    guide_step_4: "选择 Custom distribution，目标选你自己的店铺。"
    guide_step_5: "把 Client ID 与 Client Secret 复制到下方表单。"
```

- [ ] **Step 4: Rewrite the connect section of the view**

In `app/views/shopify_stores/index.html.erb`, replace lines 6-59 (the "Informational card for first-time install" block and the "Inline form to reauthorize" block — everything between the `<h1>` heading div and the `<% if @shopify_stores.any? %>` line) with:

```erb
  <%# Single connect form: handles both first-time connection and re-authorization %>
  <div class="mt-6 bg-white shadow-sm rounded-lg border border-gray-200 p-6">
    <h2 class="text-sm font-semibold text-gray-900"><%= t("shopify_stores.connect_title") %></h2>
    <p class="mt-1 text-sm text-gray-600"><%= t("shopify_stores.connect_description") %></p>

    <%# Collapsible merchant setup guide %>
    <details class="mt-4 bg-gray-50 border border-gray-200 rounded-md p-4">
      <summary class="text-sm font-medium text-gray-700 cursor-pointer"><%= t("shopify_stores.guide_summary") %></summary>
      <ol class="mt-3 ml-4 list-decimal space-y-1 text-sm text-gray-600">
        <li><%= t("shopify_stores.guide_step_1") %></li>
        <li><%= t("shopify_stores.guide_step_2_html", callback_url: shopify_callback_url(locale: nil)).html_safe %></li>
        <li><%= t("shopify_stores.guide_step_3") %></li>
        <li><%= t("shopify_stores.guide_step_4") %></li>
        <li><%= t("shopify_stores.guide_step_5") %></li>
      </ol>
    </details>

    <%= form_tag shopify_auth_path, method: :get, data: { turbo: false }, class: "mt-4 space-y-3" do %>
      <div>
        <label for="shop" class="block text-sm font-medium text-gray-500 mb-1"><%= t("shopify_stores.enter_shop_domain") %></label>
        <input type="text" name="shop" id="shop"
               placeholder="<%= t("shopify_stores.shop_domain_placeholder") %>"
               required
               class="block w-full px-3 py-2 bg-white border border-gray-300 rounded-md text-sm text-gray-700 focus:border-gray-900 focus:ring-gray-900" />
      </div>
      <div>
        <label for="client_id" class="block text-sm font-medium text-gray-500 mb-1"><%= t("shopify_stores.client_id_label") %></label>
        <input type="text" name="client_id" id="client_id" required
               class="block w-full px-3 py-2 bg-white border border-gray-300 rounded-md text-sm text-gray-700 focus:border-gray-900 focus:ring-gray-900" />
      </div>
      <div>
        <label for="client_secret" class="block text-sm font-medium text-gray-500 mb-1"><%= t("shopify_stores.client_secret_label") %></label>
        <input type="password" name="client_secret" id="client_secret" required
               class="block w-full px-3 py-2 bg-white border border-gray-300 rounded-md text-sm text-gray-700 focus:border-gray-900 focus:ring-gray-900" />
      </div>
      <% if company_has_groups? %>
        <% if current_membership&.owner? %>
          <div>
            <label for="group_id" class="block text-sm font-medium text-gray-500 mb-1"><%= t("shopify_stores.group") %></label>
            <%= select_tag :group_id,
                options_for_select(current_company.groups.order(:name).map { |g| [ g.name, g.id ] }),
                include_blank: t("shopify_stores.select_group"), required: true,
                class: "block w-full px-3 py-2 bg-white border border-gray-300 rounded-md text-sm text-gray-700 focus:border-gray-900 focus:ring-gray-900" %>
          </div>
        <% elsif current_group %>
          <%= hidden_field_tag :group_id, current_group.id %>
        <% end %>
      <% end %>
      <button type="submit"
              class="inline-flex items-center gap-2 px-4 py-2 bg-gray-900 text-white text-sm font-medium rounded-md hover:bg-gray-800 focus:outline-none focus:ring-2 focus:ring-gray-900 focus:ring-offset-2">
        <%= t("shopify_stores.connect") %>
      </button>
    <% end %>
  </div>
```

- [ ] **Step 5: Verify locales load and the page renders**

Run: `bundle exec rspec spec/requests/shopify_oauth_spec.rb -e "rejects a missing client_id"`
Expected: PASS — confirms `t("shopify_stores.credentials_required")` resolves.

Run: `bin/rails runner 'puts I18n.t("shopify_stores.connect_title", locale: :"zh-TW"); puts I18n.t("shopify_stores.connect_title", locale: :"zh-CN")'`
Expected: prints the Traditional and Simplified Chinese titles (no `translation missing`).

- [ ] **Step 6: Commit**

```bash
git add app/views/shopify_stores/index.html.erb config/locales/en.yml config/locales/zh-TW.yml config/locales/zh-CN.yml
git commit -m "feat: single Shopify connect form with per-store credentials and setup guide"
```

---

## Task 8: System spec — connect form

**Files:**
- Create: `spec/system/shopify_stores_spec.rb`

- [ ] **Step 1: Write the system spec**

Create `spec/system/shopify_stores_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Shopify stores", type: :system do
  let(:user) { create(:user) }

  before { sign_in user }

  it "renders the connect form with all three credential fields and the guide" do
    visit shopify_stores_path

    expect(page).to have_content(I18n.t("shopify_stores.connect_title"))
    expect(page).to have_field("shop")
    expect(page).to have_field("client_id")
    expect(page).to have_field("client_secret")
    expect(page).to have_content(I18n.t("shopify_stores.guide_summary"))
  end

  it "submits the form and redirects the browser to Shopify's authorize URL" do
    visit shopify_stores_path

    fill_in "shop", with: "my-test-store.myshopify.com"
    fill_in "client_id", with: "merchant-client-id"
    fill_in "client_secret", with: "merchant-client-secret"
    click_button I18n.t("shopify_stores.connect")

    # The app issues a redirect to Shopify; the external host won't load in the
    # test driver, but the controller having built the redirect is enough to
    # confirm the form wiring. Assert the session was primed instead.
    expect(page.driver.browser.current_url).to include("admin/oauth/authorize").or include("my-test-store.myshopify.com")
  end
end
```

Note: if the rack-test/headless driver cannot follow the cross-host redirect cleanly, the second example may need the assertion relaxed to confirm no error page rendered (`expect(page).not_to have_content("error")`). Keep the first example as the primary guarantee; adjust the second only if the driver forces it.

- [ ] **Step 2: Run the system spec**

Run: `bundle exec rspec spec/system/shopify_stores_spec.rb`
Expected: the first example PASSES. If the second example fails purely due to cross-host redirect handling in the driver, relax its assertion as noted, then re-run until green.

- [ ] **Step 3: Commit**

```bash
git add spec/system/shopify_stores_spec.rb
git commit -m "test: system spec for the Shopify connect form"
```

---

## Task 9: Full-suite verification + PR

**Files:** none modified.

- [ ] **Step 1: Run RuboCop**

Run: `bin/rubocop`
Expected: no offenses. If any appear, run `bin/rubocop -a`, review the diff, and commit with `style: rubocop autocorrect`.

- [ ] **Step 2: Run Brakeman**

Run: `bin/brakeman --no-pager -q`
Expected: no new warnings.

- [ ] **Step 3: Run the full non-system suite**

Run: `bundle exec rspec --exclude-pattern "spec/system/**/*"`
Expected: all green, line coverage ≥ 95%. The changes are confined to the Shopify auth/webhook path plus the model; investigate any unrelated failure before proceeding.

- [ ] **Step 4: Run the system suite**

Run: `bundle exec rspec spec/system`
Expected: all green.

- [ ] **Step 5: Manual smoke test**

Start the server with the legacy ENV vars still set:

`SHOPIFY_CLIENT_ID=dev-client-id SHOPIFY_CLIENT_SECRET=dev-client-secret bin/dev`

Sign in, visit `/shopify_stores`. Verify:
1. The single connect form renders with Shop Domain, Client ID, Client Secret fields.
2. The collapsible guide expands and shows the callback URL.
3. Submitting with a blank Client ID or Client Secret returns to the page with the `credentials_required` alert.
4. Submitting with all fields filled redirects the browser toward `https://<shop>/admin/oauth/authorize` (it will not complete without a real app, which is expected).

Stop the server: Ctrl-C.

- [ ] **Step 6: Push and open the PR**

```bash
git push -u origin feature/shopify-per-store-credentials
gh pr create --base staging --title "feat: Shopify per-store credentials" --body "$(cat <<'EOF'
## Summary
- `client_id` / `client_secret` move from a single global ENV-based app to encrypted per-store columns on `ShopifyStore`
- The `add_credentials_to_shopify_stores` migration backfills existing stores from the legacy global ENV via `ShopifyStore.backfill_credentials_from_env!`
- `ShopifyOauthController#auth` reads credentials from the connect form and stashes them in the session for the OAuth round-trip; `#callback` consumes them and writes them onto the store
- `ShopifyWebhooksController` verifies HMAC with the per-store `client_secret`, looked up by the shop-domain header; unknown shops skip HMAC (GDPR topics → 200, others → 404)
- The `shopify_stores` page becomes a single three-field connect form (used for both first-time connect and re-auth) with a collapsible merchant setup guide

## Deploy sequence
1. The migration backfills from `SHOPIFY_CLIENT_ID` / `SHOPIFY_CLIENT_SECRET` — these ENV vars **must still be present** when the migration runs
2. After deploy, no code references the global ENV vars; they can be removed from the environment

## Test plan
- [ ] CI green (RuboCop, Brakeman, RSpec unit + request + system)
- [ ] Before merging to production: confirm the prod environment still has the legacy ENV vars set so the migration backfill succeeds
- [ ] After staging deploy: connect a real test store end-to-end with a merchant-created custom app
- [ ] Verify an existing (backfilled) store's webhooks still verify and process
EOF
)"
```

Expected: PR opened against `staging`. Report the URL.

---

## Post-merge operational notes

- The migration backfill depends on `SHOPIFY_CLIENT_ID` / `SHOPIFY_CLIENT_SECRET` being set in the environment where `db:migrate` runs. Confirm this for both staging and production before deploying.
- Once deployed and verified, the legacy global ENV vars (and any `Rails.application.credentials.shopify` entries) are no longer referenced and can be removed.
- `ShopifyStore.backfill_credentials_from_env!` becomes dead code after the migration runs; a future cleanup PR can remove it.
