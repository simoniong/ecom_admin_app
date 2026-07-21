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

  describe "sync orders button" do
    it "is visible on the packing list and shows a flash notice when clicked" do
      visit packages_path

      expect(page).to have_button(I18n.t("packages.sync_orders"))
      click_button I18n.t("packages.sync_orders")

      expect(page).to have_content(I18n.t("packages.sync_enqueued"))
    end
  end
end
