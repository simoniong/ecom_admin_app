require "rails_helper"

RSpec.describe "Parcel imports", type: :request do
  let(:user)    { create(:user) }
  let(:company) { user.companies.first }
  let(:store)   { create(:shopify_store, user: user, company: company, cost_fx_rate: 7.2) }
  let(:customer) { create(:customer, shopify_store: store) }
  let!(:order)   { create(:order, customer: customer, shopify_store: store, name: "PKS#3037") }

  # The app's test environment runs with `config.cache_store = :null_store`
  # (see config/environments/test.rb) to keep low-level caching from leaking
  # between examples — but this feature's preview/confirm handshake genuinely
  # depends on Rails.cache persisting the parsed rows between two requests.
  # Solid Cache isn't actually provisioned in this repo yet (no
  # solid_cache_entries table, no config/cache.yml), so swap in a real
  # in-process store for just this file rather than changing global test
  # config or guessing at production cache wiring.
  around do |example|
    previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = previous_cache
  end

  before { sign_in user }

  def upload(path)
    Rack::Test::UploadedFile.new(path, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
  end

  def bill(rows)
    XlsxBuilder.build(rows: rows)
  end

  # Maps each rendered `<dt>` label to its sibling `<dd>` value so specs can
  # assert on the exact numbers the preview page shows without depending on
  # controller internals.
  def summary_values(body)
    Nokogiri::HTML::Document.parse(body).css("dl > div").each_with_object({}) do |div, memo|
      label = div.at_css("dt")&.text&.strip
      value = div.at_css("dd")&.text&.strip
      memo[label] = value if label
    end
  end

  describe "GET /parcels/import" do
    it "renders the upload form for an owner" do
      get import_parcels_path
      expect(response).to have_http_status(:ok)
    end

    it "rejects a non-owner member" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member)
      sign_out user
      sign_in member

      get import_parcels_path
      expect(response).to redirect_to(authenticated_root_path)
    end

    # A member with the "parcels" permission still passes AdminController's
    # generic authorize_page! check — this isolates ParcelsController's own
    # owner-only gate (require_owner!) as the thing under test.
    it "rejects a non-owner member even when granted the parcels permission" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "parcels" ])
      sign_out user
      sign_in member

      get import_parcels_path
      expect(response).to redirect_to(authenticated_root_path)
    end
  end

  describe "POST /parcels/preview" do
    it "summarises new / overwritten / unmatched without writing anything" do
      create(:parcel, shopify_store: store, order: order, identifier: "XMBDE2012381", cost_amount: 1)

      path = bill([
        XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037"),
        XlsxBuilder.row(seq: 2, identifier: "XMBDE2012382", order_name: "PKS#3038"),  # unmatched order
        XlsxBuilder.row(seq: 3, identifier: "XMBDE2012383", order_name: "PKS#3037")
      ])

      expect {
        post preview_parcels_path, params: { shopify_store_id: store.id, file: upload(path) }
      }.not_to change(Parcel, :count)

      expect(response).to have_http_status(:ok)

      summary = summary_values(response.body)
      expect(summary[I18n.t("parcels.import.parsed")]).to eq("3")
      expect(summary[I18n.t("parcels.import.will_create")]).to eq("2")
      expect(summary[I18n.t("parcels.import.will_overwrite")]).to eq("1")
      expect(summary[I18n.t("parcels.import.unmatched")]).to eq("1")
    end

    it "blocks the import when the store has no cost_fx_rate" do
      store.update!(cost_fx_rate: nil)
      path = bill([ XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037") ])

      post preview_parcels_path, params: { shopify_store_id: store.id, file: upload(path) }

      expect(response).to redirect_to(import_parcels_path)
      expect(flash[:alert]).to be_present
    end

    it "rejects a missing file" do
      post preview_parcels_path, params: { shopify_store_id: store.id }
      expect(response).to redirect_to(import_parcels_path)
      expect(flash[:alert]).to be_present
    end

    it "rejects a non-owner member" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "parcels" ])
      sign_out user
      sign_in member

      path = bill([ XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037") ])

      expect {
        post preview_parcels_path, params: { shopify_store_id: store.id, file: upload(path) }
      }.not_to change(Parcel, :count)
      expect(response).to redirect_to(authenticated_root_path)
    end
  end

  describe "POST /parcels/confirm_import" do
    it "writes the cached rows and rolls up onto the order" do
      path = bill([
        XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: 239.73)
      ])
      post preview_parcels_path, params: { shopify_store_id: store.id, file: upload(path) }
      token = session[:parcel_import_token]

      expect {
        post confirm_import_parcels_path, params: { token: token }
      }.to change(Parcel, :count).by(1)

      expect(order.reload.actual_shipping_cost).to eq(BigDecimal("33.30"))
      expect(response).to redirect_to(parcels_path)
    end

    it "overwrites an existing parcel rather than duplicating it" do
      create(:parcel, shopify_store: store, order: order, identifier: "XMBDE2012381", cost_cny: 1, cost_amount: 1)

      path = bill([ XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: 239.73) ])
      post preview_parcels_path, params: { shopify_store_id: store.id, file: upload(path) }

      expect {
        post confirm_import_parcels_path, params: { token: session[:parcel_import_token] }
      }.not_to change(Parcel, :count)

      expect(Parcel.find_by(identifier: "XMBDE2012381").cost_cny).to eq(239.73)
    end

    it "fails cleanly when the cached preview has expired" do
      post confirm_import_parcels_path, params: { token: "nonexistent" }

      expect(response).to redirect_to(import_parcels_path)
      expect(flash[:alert]).to be_present
    end

    it "rejects a non-owner member even with a valid cached token" do
      path = bill([ XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037") ])
      post preview_parcels_path, params: { shopify_store_id: store.id, file: upload(path) }
      token = session[:parcel_import_token]

      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "parcels" ])
      sign_out user
      sign_in member

      expect {
        post confirm_import_parcels_path, params: { token: token }
      }.not_to change(Parcel, :count)
      expect(response).to redirect_to(authenticated_root_path)
    end
  end
end
