require "rails_helper"

RSpec.describe "Parcel import", type: :system do
  let(:user)     { create(:user) }
  let(:company)  { user.companies.first }
  let!(:store)   { create(:shopify_store, user: user, company: company, name: "CSFD", cost_fx_rate: 7.2) }
  let(:customer) { create(:customer, shopify_store: store) }
  let!(:order)   { create(:order, customer: customer, shopify_store: store, name: "PKS#3037", estimated_shipping_cost: 20) }

  before { sign_in_as(user) }

  def summary_value(label)
    find("dt", text: label, exact_text: true).find(:xpath, "following-sibling::dd[1]").text
  end

  it "uploads, previews, confirms and lands the data" do
    path = XlsxBuilder.build(rows: [
      XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: 239.73),
      XlsxBuilder.row(seq: 2, identifier: "XMBDE2012382", order_name: "PKS#9999", cost: 65.57)
    ])

    visit import_parcels_path

    select "CSFD", from: "shopify_store_id"
    attach_file "file", path
    click_button I18n.t("parcels.import.parse")

    # Preview page — must show the counts but must NOT have written anything
    # to the database yet. This is the feature's main safety property: a
    # merchant reviews the money figures before anything is committed.
    expect(page).to have_content(I18n.t("parcels.import.preview_title"))
    expect(page).to have_content(I18n.t("parcels.import.unmatched_hint"))
    expect(page).to have_content("XMBDE2012382") # the unmatched row is called out by identifier
    expect(summary_value(I18n.t("parcels.import.will_create"))).to eq("2")
    expect(summary_value(I18n.t("parcels.import.will_overwrite"))).to eq("0")
    expect(summary_value(I18n.t("parcels.import.unmatched"))).to eq("1")
    expect(Parcel.count).to eq(0)
    expect(ParcelImportBatch.pending.count).to eq(1)

    # Post/Redirect/Get: the preview lives at its own GET URL, so reloading it
    # re-renders the same staged batch instead of re-POSTing the upload.
    page.refresh
    expect(page).to have_content(I18n.t("parcels.import.preview_title"))
    expect(summary_value(I18n.t("parcels.import.will_create"))).to eq("2")
    expect(Parcel.count).to eq(0)

    click_button I18n.t("parcels.import.confirm")

    expect(page).to have_content(I18n.t("parcels.import.done", count: 2))
    expect(Parcel.count).to eq(2)
    expect(Parcel.find_by(identifier: "XMBDE2012382").order_id).to be_nil # unmatched, still imported
    expect(order.reload.actual_shipping_cost).to eq(33.30) # 239.73 / 7.2, rounded
    expect(ParcelImportBatch.pending.count).to eq(0)
  end

  it "blocks the import when the store has no fx rate, and writes nothing" do
    store.update!(cost_fx_rate: nil)
    path = XlsxBuilder.build(rows: [ XlsxBuilder.row(seq: 1, identifier: "X1", order_name: "PKS#3037") ])

    visit import_parcels_path
    select "CSFD", from: "shopify_store_id"
    attach_file "file", path
    click_button I18n.t("parcels.import.parse")

    expect(page).to have_content(I18n.t("parcels.import.fx_rate_missing", store: "CSFD"))
    expect(page).to have_current_path(import_parcels_path)
    expect(Parcel.count).to eq(0)
    expect(ParcelImportBatch.count).to eq(0)
  end
end
