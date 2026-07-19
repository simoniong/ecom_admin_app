require "rails_helper"

RSpec.describe "Product Customs UI", type: :system do
  let(:user) { create(:user) }
  let(:store) { create(:shopify_store, user: user, company: user.companies.first) }
  let(:product) { create(:product, shopify_store: store, title: "Paint Kit") }
  let!(:variant) { create(:product_variant, product: product, sku: "PK-BL", title: "Black/Large") }
  let!(:complete_variant) do
    create(:product_variant, product: product, sku: "PK-COMPLETE",
           customs_name_zh: "積木", customs_name_en: "Blocks",
           declared_value_usd: 5, weight_grams: 100)
  end

  before { sign_in_as(user) }

  it "shows variants with a completion badge on the customs page" do
    visit product_customs_path(store_id: store.id)
    expect(page).to have_content(I18n.t("product_customs.title"))
    expect(page).to have_content("PK-BL")
    expect(page).to have_content("PK-COMPLETE")
    expect(page).to have_content(I18n.t("product_customs.status.incomplete"))
    expect(page).to have_content(I18n.t("product_customs.status.complete"))
  end

  it "inline-edits a SKU's customs info via Turbo Stream, and rejects a blank required field" do
    visit product_customs_path(store_id: store.id)

    within("##{ActionView::RecordIdentifier.dom_id(variant)}") do
      find("[data-cell-edit-field-value='customs_name_zh'] [data-cell-edit-target='display']").click
      find("[data-cell-edit-field-value='customs_name_zh'] input").set("積木")
      find("[data-cell-edit-field-value='customs_name_zh'] input").send_keys(:tab)
    end

    # customs_name_zh alone (with the other three still blank) must be
    # rejected — enforce required-together — so the badge stays "incomplete"
    # and the saved cell reverts (nothing persisted).
    expect(variant.reload.customs_name_zh).to be_nil

    within("##{ActionView::RecordIdentifier.dom_id(variant)}") do
      expect(page).to have_content(I18n.t("product_customs.status.incomplete"))
    end
  end

  it "narrows the list with the 只顯示未完成 / incomplete-only filter" do
    visit product_customs_path(store_id: store.id)
    expect(page).to have_content("PK-COMPLETE")

    check I18n.t("product_customs.only_incomplete")

    expect(page).to have_content("PK-BL")
    expect(page).to have_no_content("PK-COMPLETE")
  end
end
