require "rails_helper"

RSpec.describe "Packages", type: :request do
  let(:user)    { create(:user) }
  let(:company) { user.companies.first }
  let(:store)   { create(:shopify_store, user: user, company: company) }
  let(:customer) { create(:customer, shopify_store: store) }

  let!(:review_package) do
    order = create(:order, customer: customer, shopify_store: store, name: "PKS#1001")
    create(:package, shopify_store: store, order: order, aasm_state: "pending_review", number: 1)
  end

  let!(:process_package) do
    order = create(:order, customer: customer, shopify_store: store, name: "PKS#1002")
    create(:package, shopify_store: store, order: order, aasm_state: "pending_process", number: 2)
  end

  before { sign_in user }

  describe "GET /packages" do
    it "returns 200 and shows the pending_review packages by default" do
      get packages_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("PKS#1001")
      expect(response.body).not_to include("PKS#1002")
    end

    it "filters to the requested state only" do
      get packages_path, params: { state: "pending_process" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("PKS#1002")
      expect(response.body).not_to include("PKS#1001")
    end

    it "renders the package's items (sku x qty)" do
      create(:package_item, package: review_package, sku: "SKU-ABC", title: "Widget", quantity: 3)
      get packages_path
      expect(response.body).to include("SKU-ABC")
      expect(response.body).to include("Widget")
      expect(response.body).to include("3")
    end

    it "falls back to pending_review for an unknown state param" do
      get packages_path, params: { state: "not_a_real_state" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("PKS#1001")
    end

    describe "held list" do
      it "shows the held_from original state label for a held package" do
        order = create(:order, customer: customer, shopify_store: store, name: "PKS#3001")
        create(:package, shopify_store: store, order: order, aasm_state: "held",
               held_from: "pending_process", number: 20)

        get packages_path, params: { state: "held" }
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("PKS#3001")
        expect(response.body).to include(I18n.t("packages.states.pending_process"))
      end
    end

    describe "pagination" do
      let(:pagination_state) { "pending_label" }

      before do
        51.times do |i|
          order = create(:order, customer: customer, shopify_store: store, name: "PKS#PAG#{i}")
          create(:package, shopify_store: store, order: order, aasm_state: pagination_state, number: 1000 + i)
        end
      end

      it "shows only PER_PAGE rows on page 1 with a page-2 link that preserves the state filter" do
        get packages_path, params: { state: pagination_state }
        expect(response).to have_http_status(:ok)

        rows = response.body.scan("PKS#PAG").size
        expect(rows).to eq(PackagesController::PER_PAGE)
        expect(response.body).to include("state=#{pagination_state}")
        expect(response.body).to include("page=2")
      end

      it "shows the remainder on page 2" do
        get packages_path, params: { state: pagination_state, page: 2 }
        expect(response).to have_http_status(:ok)

        rows = response.body.scan("PKS#PAG").size
        expect(rows).to eq(51 - PackagesController::PER_PAGE)
      end
    end

    describe "applying_tracking sub-tabs (application_status)" do
      let!(:pending_application) do
        order = create(:order, customer: customer, shopify_store: store, name: "PKS#2001")
        create(:package, shopify_store: store, order: order, aasm_state: "applying_tracking",
               application_status: "pending", number: 10)
      end

      let!(:success_application) do
        order = create(:order, customer: customer, shopify_store: store, name: "PKS#2002")
        create(:package, shopify_store: store, order: order, aasm_state: "applying_tracking",
               application_status: "succeeded", number: 11)
      end

      it "shows every applying_tracking package with no application_status filter" do
        get packages_path, params: { state: "applying_tracking" }
        expect(response.body).to include("PKS#2001")
        expect(response.body).to include("PKS#2002")
      end

      it "filters to only the pending sub-status" do
        get packages_path, params: { state: "applying_tracking", application_status: "pending" }
        expect(response.body).to include("PKS#2001")
        expect(response.body).not_to include("PKS#2002")
      end

      it "filters to only the succeeded sub-status" do
        get packages_path, params: { state: "applying_tracking", application_status: "succeeded" }
        expect(response.body).to include("PKS#2002")
        expect(response.body).not_to include("PKS#2001")
      end
    end

    describe "cross-company isolation" do
      it "never shows a package that belongs to another company's store" do
        other_user = create(:user)
        other_company = other_user.companies.first
        other_store = create(:shopify_store, user: other_user, company: other_company)
        other_customer = create(:customer, shopify_store: other_store)
        other_order = create(:order, customer: other_customer, shopify_store: other_store, name: "OTHER#9999")
        create(:package, shopify_store: other_store, order: other_order, aasm_state: "pending_review", number: 1)

        get packages_path
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("OTHER#9999")
      end
    end

    describe "permission gate (any packing permission)" do
      it "allows a member granted package_review" do
        member = create(:user)
        create(:membership, user: member, company: company, role: :member, permissions: [ "package_review" ])
        sign_out user
        sign_in member

        get packages_path
        expect(response).to have_http_status(:ok)
      end

      it "allows a member granted package_process" do
        member = create(:user)
        create(:membership, user: member, company: company, role: :member, permissions: [ "package_process" ])
        sign_out user
        sign_in member

        get packages_path
        expect(response).to have_http_status(:ok)
      end

      it "allows a member granted package_shipping" do
        member = create(:user)
        create(:membership, user: member, company: company, role: :member, permissions: [ "package_shipping" ])
        sign_out user
        sign_in member

        get packages_path
        expect(response).to have_http_status(:ok)
      end

      it "denies a member with only the orders permission (redirect)" do
        member = create(:user)
        create(:membership, user: member, company: company, role: :member, permissions: [ "orders" ])
        sign_out user
        sign_in member

        get packages_path
        expect(response).to redirect_to(authenticated_root_path)
      end
    end
  end
end
