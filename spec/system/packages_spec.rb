require "rails_helper"

RSpec.describe "Packages UI", type: :system do
  let(:user) { create(:user) }
  let(:company) { user.companies.first }
  let(:store) { create(:shopify_store, user: user, company: company) }
  let(:customer) { create(:customer, shopify_store: store) }

  let!(:review_package) do
    order = create(:order, customer: customer, shopify_store: store, name: "PKS#3001")
    create(:package, shopify_store: store, order: order, aasm_state: "pending_review", number: 1)
  end

  let!(:process_package) do
    order = create(:order, customer: customer, shopify_store: store, name: "PKS#3002")
    create(:package, shopify_store: store, order: order, aasm_state: "pending_process", number: 2)
  end

  before { sign_in_as(user) }

  describe "打包 nav-group" do
    it "expands to reveal the package state links with counts, and clicking 待審核 shows its packages" do
      visit authenticated_root_path

      within "nav" do
        expect(page).to have_no_css("#packing-menu", visible: :visible)
        click_button I18n.t("nav.packing")
        expect(page).to have_css("#packing-menu", visible: :visible)
        expect(page).to have_link(I18n.t("packages.states.pending_review"))
        expect(page).to have_link(I18n.t("packages.states.pending_process"))
        expect(page).to have_link(I18n.t("packages.states.applying_tracking"))
        expect(page).to have_link(I18n.t("packages.states.pending_label"))
        expect(page).to have_link(I18n.t("packages.states.shipped"))
        expect(page).to have_link(I18n.t("packages.states.refunded"))
        expect(page).to have_link(I18n.t("packages.states.held"))

        click_link I18n.t("packages.states.pending_review")
      end

      expect(page).to have_content("PKS#3001")
      expect(page).to have_no_content("PKS#3002")
    end

    it "renders a count badge next to each state reflecting the number of packages in it" do
      visit authenticated_root_path

      within "nav" do
        click_button I18n.t("nav.packing")
        review_link = find("a", text: I18n.t("packages.states.pending_review"))
        expect(review_link).to have_content("1")
      end
    end
  end

  describe "item refund warnings on the list" do
    it "shows the do-not-ship badge for a fully-refunded item" do
      create(:package_item, package: review_package, sku: "WP-1", quantity: 2, refunded_quantity: 2)

      visit packages_path

      expect(page).to have_content(I18n.t("packages.item_refunded", n: 2, total: 2))
      expect(page).to have_content(I18n.t("packages.do_not_ship"))
    end
  end

  describe "sync orders button" do
    it "is visible on the packing list and shows a flash notice when clicked" do
      visit packages_path

      expect(page).to have_button(I18n.t("packages.sync_orders"))
      click_button I18n.t("packages.sync_orders")

      expect(page).to have_content(I18n.t("packages.sync_enqueued"))
    end
  end

  describe "package detail modal" do
    it "opens from the list, switches tabs, and closes" do
      create(:package_item, package: review_package, sku: "SKU-MODAL", title: "Modal Widget", quantity: 1)

      visit packages_path
      click_link review_package.package_code

      expect(page).to have_css("[data-modal-target='dialog']", visible: :visible)
      expect(page).to have_content(I18n.t("packages.detail_title", code: review_package.package_code))
      expect(page).to have_content(I18n.t("packages.states.pending_review"))
      expect(page).to have_content(I18n.t("packages.tabs.address"))
      expect(page).to have_content("SKU-MODAL")

      within("[data-modal-target='dialog']") do
        click_button I18n.t("packages.tabs.customs")
      end
      expect(page).to have_css("##{ActionView::RecordIdentifier.dom_id(review_package, :customs)}", visible: :visible)
      expect(page).to have_no_css("##{ActionView::RecordIdentifier.dom_id(review_package, :address)}", visible: :visible)

      find("[data-modal-target='dialog'] button[aria-label='#{I18n.t('packages.close')}']").click
      expect(page).to have_css("[data-modal-target='dialog']", visible: :hidden)
    end
  end

  describe "state operations in the detail modal" do
    it "advances pending_review -> pending_process via the review button, then holds it" do
      visit packages_path
      click_link review_package.package_code

      within("[data-modal-target='dialog']") do
        expect(page).to have_content(I18n.t("packages.states.pending_review"))
        click_button I18n.t("packages.actions.review")

        expect(page).to have_content(I18n.t("packages.detail_title", code: review_package.package_code))
        expect(page).to have_button(I18n.t("packages.actions.back_to_review"))
      end
      expect(review_package.reload.aasm_state).to eq("pending_process")

      within("[data-modal-target='dialog']") do
        click_button I18n.t("packages.actions.hold")
        expect(page).to have_content(I18n.t("packages.states.held"))
      end
      expect(review_package.reload.aasm_state).to eq("held")
      expect(review_package.held_from).to eq("pending_process")
    end
  end

  describe "editing the shipping address in the detail modal" do
    it "toggles to the edit form, saves, and shows the new value with the incomplete badge cleared" do
      visit packages_path
      click_link review_package.package_code

      within("[data-modal-target='dialog']") do
        expect(page).to have_content(I18n.t("packages.address_fields.incomplete"))

        click_button I18n.t("packages.edit")
        fill_in "address[name]", with: "Jane Doe"
        fill_in "address[address1]", with: "1 Main St"
        fill_in "address[city]", with: "Springfield"
        fill_in "address[country_code]", with: "US"
        fill_in "address[country]", with: "United States"
        click_button I18n.t("packages.save")

        expect(page).to have_content("Jane Doe")
        expect(page).to have_content("1 Main St")
        expect(page).to have_content("Springfield")
        expect(page).to have_no_content(I18n.t("packages.address_fields.incomplete"))
      end

      review_package.reload
      expect(review_package.address_overridden).to be(true)
      expect(review_package.address_complete?).to be(true)
    end
  end

  describe "editing per-item customs in the detail modal" do
    it "saves an item's customs fields, reflects them in the row, and clears the customs badge when all items are complete" do
      create(:package_item, package: review_package, sku: "SKU-CUSTOMS", title: "Customs Widget", quantity: 1)

      visit packages_path
      click_link review_package.package_code

      within("[data-modal-target='dialog']") do
        click_button I18n.t("packages.tabs.customs")
      end

      expect(page).to have_content(I18n.t("packages.customs_fields.incomplete"))

      find("input[name='package_item[customs_name_zh]']").set("小工具")
      find("input[name='package_item[customs_name_en]']").set("Widget")
      find("input[name='package_item[declared_value_usd]']").set("9.99")
      find("input[name='package_item[customs_weight_grams]']").set("88")
      click_button I18n.t("packages.save")

      expect(page).to have_field("package_item[customs_name_zh]", with: "小工具")
      expect(page).to have_field("package_item[customs_name_en]", with: "Widget")
      expect(page).to have_no_content(I18n.t("packages.customs_fields.incomplete"))

      item = review_package.reload.package_items.find_by(sku: "SKU-CUSTOMS")
      expect(item.customs_overridden).to be(true)
      expect(item.customs_complete?).to be(true)
    end
  end
end
