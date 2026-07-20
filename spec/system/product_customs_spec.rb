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

  it "saves a row's customs info via the per-row Save button (all fields together)" do
    visit product_customs_path(store_id: store.id)

    within("##{ActionView::RecordIdentifier.dom_id(variant)}") do
      find("input[name='product_variant[customs_name_zh]']").set("積木")
      find("input[name='product_variant[customs_name_en]']").set("Blocks")
      find("input[name='product_variant[declared_value_usd]']").set("9.99")
      find("input[name='product_variant[weight_grams]']").set("120")
      click_button I18n.t("product_customs.save")
    end

    within("##{ActionView::RecordIdentifier.dom_id(variant)}") do
      expect(page).to have_content(I18n.t("product_customs.status.complete"))
    end
    variant.reload
    expect(variant.customs_name_zh).to eq("積木")
    expect(variant.customs_name_en).to eq("Blocks")
    expect(variant.declared_value_usd).to eq(9.99)
    expect(variant.weight_grams).to eq(120)
  end

  it "rejects a row save that leaves weight_grams blank, showing an inline error and saving nothing" do
    visit product_customs_path(store_id: store.id)

    within("##{ActionView::RecordIdentifier.dom_id(variant)}") do
      find("input[name='product_variant[customs_name_zh]']").set("積木")
      find("input[name='product_variant[customs_name_en]']").set("Blocks")
      find("input[name='product_variant[declared_value_usd]']").set("9.99")
      # weight_grams left blank on purpose — required-together must reject
      # the whole row, not save the other three fields.
      click_button I18n.t("product_customs.save")

      expect(page).to have_content("can't be blank")
      expect(page).to have_content(I18n.t("product_customs.status.incomplete"))
    end

    variant.reload
    expect(variant.customs_name_zh).to be_nil
    expect(variant.customs_name_en).to be_nil
    expect(variant.declared_value_usd).to be_nil
  end

  it "narrows the list with the 只顯示未完成 / incomplete-only filter" do
    visit product_customs_path(store_id: store.id)
    expect(page).to have_content("PK-COMPLETE")

    check I18n.t("product_customs.only_incomplete")

    expect(page).to have_content("PK-BL")
    expect(page).to have_no_content("PK-COMPLETE")
  end
end
