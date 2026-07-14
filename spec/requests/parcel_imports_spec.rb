require "rails_helper"

RSpec.describe "Parcel imports", type: :request do
  let(:user)    { create(:user) }
  let(:company) { user.companies.first }
  let(:store)   { create(:shopify_store, user: user, company: company, cost_fx_rate: 7.2) }
  let(:customer) { create(:customer, shopify_store: store) }
  let!(:order)   { create(:order, customer: customer, shopify_store: store, name: "PKS#3037") }

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

  # The preview page carries the staged ParcelImportBatch id via the confirm
  # button's hidden field rather than a cache token — pull it back out of the
  # rendered form so specs exercise the same handshake a real browser would.
  def batch_id_from(body)
    Nokogiri::HTML::Document.parse(body).at_css('input[name="batch_id"]')["value"]
  end

  # POST /parcels/preview is Post/Redirect/Get: it stages the batch and
  # redirects to the GET that renders it. Follow the redirect the way a browser
  # would, and hand back the rendered preview body.
  def preview_upload(path, shopify_store_id: store.id)
    post preview_parcels_path, params: { shopify_store_id: shopify_store_id, file: upload(path) }
    follow_redirect! if response.redirect? && response.location.include?("/parcels/preview/")
    response.body
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

      body = nil
      expect { body = preview_upload(path) }.not_to change(Parcel, :count)

      expect(response).to have_http_status(:ok)

      summary = summary_values(body)
      expect(summary[I18n.t("parcels.import.parsed")]).to eq("3")
      expect(summary[I18n.t("parcels.import.will_create")]).to eq("2")
      expect(summary[I18n.t("parcels.import.will_overwrite")]).to eq("1")
      expect(summary[I18n.t("parcels.import.unmatched")]).to eq("1")
    end

    # Turbo Drive refuses any response to a non-GET form submission that is not
    # a redirect or a turbo_stream ("Form responses must redirect to another
    # location"). Rendering the preview inline left the browser stuck on the
    # upload form with no feedback at all, which is how this shipped unnoticed:
    # every request spec was happy with the 200.
    it "redirects to the staged batch's own GET url rather than rendering inline" do
      path = bill([ XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037") ])

      post preview_parcels_path, params: { shopify_store_id: store.id, file: upload(path) }

      batch = ParcelImportBatch.pending.sole
      expect(response).to redirect_to(show_preview_parcels_path(batch_id: batch.id))
    end

    it "stages a pending ParcelImportBatch instead of writing parcels" do
      path = bill([
        XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037"),
        XlsxBuilder.row(seq: 2, identifier: "XMBDE2012382", order_name: "PKS#3037")
      ])

      expect { preview_upload(path) }.to change(ParcelImportBatch, :count).by(1)

      batch = ParcelImportBatch.last
      expect(batch).to be_pending
      expect(batch.shopify_store).to eq(store)
      expect(batch.user).to eq(user)
      expect(batch.row_count).to eq(2)
      expect(batch.filename).to end_with(".xlsx")
    end

    it "deletes the user's own previous pending batch for the same store on re-upload" do
      path = bill([ XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037") ])

      post preview_parcels_path, params: { shopify_store_id: store.id, file: upload(path) }
      first_batch_id = ParcelImportBatch.pending.sole.id

      post preview_parcels_path, params: { shopify_store_id: store.id, file: upload(path) }

      expect(ParcelImportBatch.pending.count).to eq(1)
      expect(ParcelImportBatch.exists?(first_batch_id)).to be(false)
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

  describe "GET /parcels/preview/:batch_id" do
    def stage_batch(rows, as_store: store)
      preview_upload(bill(rows), shopify_store_id: as_store.id)
      ParcelImportBatch.pending.order(:created_at).last
    end

    it "renders the staged batch, still without writing any parcels" do
      batch = stage_batch([
        XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037"),
        XlsxBuilder.row(seq: 2, identifier: "XMBDE2012382", order_name: "PKS#3038")
      ])

      expect { get show_preview_parcels_path(batch_id: batch.id) }.not_to change(Parcel, :count)

      expect(response).to have_http_status(:ok)
      summary = summary_values(response.body)
      expect(summary[I18n.t("parcels.import.parsed")]).to eq("2")
      expect(summary[I18n.t("parcels.import.unmatched")]).to eq("1")
    end

    # The money figures on this page are read back out of a jsonb column, where
    # a BigDecimal round-trips as a JSON string. Summing those raw would raise
    # or concatenate, so the totals are the thing that proves the rehydration.
    it "rehydrates jsonb money back into BigDecimal for the totals" do
      batch = stage_batch([
        XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: 239.73),
        XlsxBuilder.row(seq: 2, identifier: "XMBDE2012382", order_name: "PKS#3037", cost: 65.57)
      ])

      get show_preview_parcels_path(batch_id: batch.id)

      expect(batch.staged_rows.sum { |r| r[:cost_cny] }).to eq(BigDecimal("305.30"))
      expect(summary_values(response.body)[I18n.t("parcels.import.total_cny")]).to include("305.30")
    end

    it "is reloadable — a second GET renders the same staged batch" do
      batch = stage_batch([ XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037") ])

      2.times { get show_preview_parcels_path(batch_id: batch.id) }

      expect(response).to have_http_status(:ok)
      expect(summary_values(response.body)[I18n.t("parcels.import.parsed")]).to eq("1")
      expect(Parcel.count).to eq(0)
    end

    it "refuses a batch belonging to another company's store" do
      other_user  = create(:user)
      other_store = create(:shopify_store, user: other_user, company: other_user.companies.first, cost_fx_rate: 5)
      other_customer = create(:customer, shopify_store: other_store)
      create(:order, customer: other_customer, shopify_store: other_store, name: "PKS#9999")

      sign_out user
      sign_in other_user
      foreign_batch = stage_batch([ XlsxBuilder.row(seq: 1, identifier: "OTHERCO0001", order_name: "PKS#9999") ],
                                  as_store: other_store)

      sign_out other_user
      sign_in user

      get show_preview_parcels_path(batch_id: foreign_batch.id)

      expect(response).to redirect_to(import_parcels_path)
      expect(flash[:alert]).to be_present
      expect(response.body).not_to include("OTHERCO0001")
    end

    it "fails cleanly for an unknown batch id" do
      get show_preview_parcels_path(batch_id: SecureRandom.uuid)

      expect(response).to redirect_to(import_parcels_path)
      expect(flash[:alert]).to eq(I18n.t("parcels.import.expired"))
    end

    # An already-confirmed batch must not render as if it were still pending —
    # otherwise the confirm button would invite a double import.
    it "fails cleanly for an already-confirmed batch" do
      batch = stage_batch([ XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037") ])
      post confirm_import_parcels_path, params: { batch_id: batch.id }

      get show_preview_parcels_path(batch_id: batch.id)

      expect(response).to redirect_to(import_parcels_path)
      expect(flash[:alert]).to eq(I18n.t("parcels.import.expired"))
    end

    it "rejects a non-owner member" do
      batch = stage_batch([ XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037") ])

      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "parcels" ])
      sign_out user
      sign_in member

      get show_preview_parcels_path(batch_id: batch.id)

      expect(response).to redirect_to(authenticated_root_path)
    end
  end

  describe "POST /parcels/confirm_import" do
    it "writes the staged rows and rolls up onto the order" do
      path = bill([
        XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: 239.73)
      ])
      batch_id = batch_id_from(preview_upload(path))

      expect {
        post confirm_import_parcels_path, params: { batch_id: batch_id }
      }.to change(Parcel, :count).by(1)

      expect(order.reload.actual_shipping_cost).to eq(BigDecimal("33.30"))
      expect(response).to redirect_to(parcels_path)
      expect(ParcelImportBatch.find(batch_id)).to be_completed
      expect(ParcelImportBatch.find(batch_id).completed_at).to be_present
    end

    # This is the jsonb round-trip guarantee the design doc calls out (§4.2.1
    # / task instructions): rows pass through a jsonb column between preview
    # and confirm, so on read-back every value is a JSON scalar (strings for
    # money and timestamps, not the original BigDecimal/Time objects). If
    # that round trip silently lost precision or truncated a timestamp, the
    # resulting Parcel would carry wrong financial data.
    it "round-trips row values through jsonb without precision or truncation loss" do
      shipped_at = Time.utc(2026, 6, 1, 21, 48, 26)
      path = bill([
        XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: 239.73)
      ])
      batch_id = batch_id_from(preview_upload(path))

      post confirm_import_parcels_path, params: { batch_id: batch_id }

      parcel = Parcel.find_by!(identifier: "XMBDE2012381")
      expect(parcel.cost_cny).to eq(BigDecimal("239.73"))
      expect(parcel.cost_amount).to eq(BigDecimal("33.30"))
      expect(parcel.shipped_at).to be_within(1.second).of(shipped_at)
      expect(parcel.order_id).to eq(order.id)
    end

    it "overwrites an existing parcel rather than duplicating it" do
      create(:parcel, shopify_store: store, order: order, identifier: "XMBDE2012381", cost_cny: 1, cost_amount: 1)

      path = bill([ XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: 239.73) ])
      batch_id = batch_id_from(preview_upload(path))

      expect {
        post confirm_import_parcels_path, params: { batch_id: batch_id }
      }.not_to change(Parcel, :count)

      expect(Parcel.find_by(identifier: "XMBDE2012381").cost_cny).to eq(239.73)
    end

    it "fails cleanly when the batch has expired (never existed)" do
      post confirm_import_parcels_path, params: { batch_id: "nonexistent" }

      expect(response).to redirect_to(import_parcels_path)
      expect(flash[:alert]).to be_present
    end

    it "fails cleanly when the batch was already confirmed (double submit)" do
      path = bill([ XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037") ])
      batch_id = batch_id_from(preview_upload(path))
      post confirm_import_parcels_path, params: { batch_id: batch_id }

      expect {
        post confirm_import_parcels_path, params: { batch_id: batch_id }
      }.not_to change(Parcel, :count)
      expect(response).to redirect_to(import_parcels_path)
      expect(flash[:alert]).to be_present
    end

    # Authorization boundary: a batch belongs to a shopify_store, which
    # belongs to a company. confirm_import must scope its lookup to the
    # signed-in user's own visible_shopify_stores — otherwise any owner could
    # confirm (and thereby write Parcel rows / mutate financial rollups for)
    # another company's in-flight import just by guessing/observing its id.
    it "refuses to confirm a batch that belongs to another company's store" do
      other_user  = create(:user)
      other_company = other_user.companies.first
      other_store = create(:shopify_store, user: other_user, company: other_company, cost_fx_rate: 5)
      other_customer = create(:customer, shopify_store: other_store)
      create(:order, customer: other_customer, shopify_store: other_store, name: "PKS#9999")

      path = bill([ XlsxBuilder.row(seq: 1, identifier: "OTHERCO0001", order_name: "PKS#9999") ])
      sign_out user
      sign_in other_user
      foreign_batch_id = batch_id_from(preview_upload(path, shopify_store_id: other_store.id))

      sign_out other_user
      sign_in user

      expect {
        post confirm_import_parcels_path, params: { batch_id: foreign_batch_id }
      }.not_to change(Parcel, :count)

      expect(response).to redirect_to(import_parcels_path)
      expect(flash[:alert]).to be_present
      expect(ParcelImportBatch.find(foreign_batch_id)).to be_pending
    end

    it "rejects a non-owner member even with a valid pending batch id" do
      path = bill([ XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037") ])
      batch_id = batch_id_from(preview_upload(path))

      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "parcels" ])
      sign_out user
      sign_in member

      expect {
        post confirm_import_parcels_path, params: { batch_id: batch_id }
      }.not_to change(Parcel, :count)
      expect(response).to redirect_to(authenticated_root_path)
    end
  end
end
