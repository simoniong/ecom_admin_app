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

      it "ignores an application_status value outside the whitelist and shows every package" do
        get packages_path, params: { state: "applying_tracking", application_status: "'; DROP TABLE packages; --" }
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("PKS#2001")
        expect(response.body).to include("PKS#2002")
      end
    end

    describe "store switcher scoping" do
      # Codex finding 2: the packages list + sidebar counts must respect the
      # currently-selected store (current_shopify_store), same as
      # OrdersController#index, instead of always aggregating across every
      # visible store.
      let!(:store_b) { create(:shopify_store, user: user, company: company) }
      let!(:customer_b) { create(:customer, shopify_store: store_b) }

      let!(:store_b_package) do
        order = create(:order, customer: customer_b, shopify_store: store_b, name: "PKS#STOREB")
        create(:package, shopify_store: store_b, order: order, aasm_state: "pending_review", number: 1)
      end

      def sidebar_badge_count(body, state_label)
        doc = Nokogiri::HTML(body)
        link = doc.at_xpath("//a[.//span[normalize-space(text())='#{state_label}']]")
        link.at_xpath(".//span[2]").text.strip.to_i
      end

      it "defaults to a single store (not an aggregate of all stores) when none is explicitly selected" do
        # Packages is switcher-visible but NOT in STORE_ALL_ALLOWED_CONTROLLERS
        # (same as Orders), so with no store_id param/session,
        # current_shopify_store resolves to visible_shopify_stores.first
        # rather than nil/"all" — scoped_packages must follow that store, not
        # silently aggregate every store's packages.
        get packages_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("PKS#1001")
        expect(response.body).not_to include("PKS#STOREB")
        expect(sidebar_badge_count(response.body, "Pending Review")).to eq(1)
      end

      it "scopes the list and sidebar counts to the selected store" do
        get packages_path, params: { store_id: store.id }
        expect(response.body).to include("PKS#1001")
        expect(response.body).not_to include("PKS#STOREB")
        expect(sidebar_badge_count(response.body, "Pending Review")).to eq(1)
      end

      it "adds packages to STORE_SWITCHER_CONTROLLERS so the switcher persists a selection" do
        get packages_path, params: { store_id: store_b.id }
        expect(session[:store_id]).to eq(store_b.id)

        get packages_path
        expect(response.body).to include("PKS#STOREB")
        expect(response.body).not_to include("PKS#1001")
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

      it "never leaks another company's package even when its store_id is passed explicitly via the switcher" do
        other_user = create(:user)
        other_company = other_user.companies.first
        other_store = create(:shopify_store, user: other_user, company: other_company)
        other_customer = create(:customer, shopify_store: other_store)
        other_order = create(:order, customer: other_customer, shopify_store: other_store, name: "OTHER#8888")
        create(:package, shopify_store: other_store, order: other_order, aasm_state: "pending_review", number: 1)

        # current_shopify_store resolves store_id against visible_shopify_stores
        # (scoped to the current company), so a foreign store_id can never
        # select a foreign store — it falls back within the current company.
        get packages_path, params: { store_id: other_store.id }
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("OTHER#8888")
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

  describe "item refund warnings on the list" do
    let(:user) { create(:user) }
    let(:company) { user.companies.first }
    let(:store) { create(:shopify_store, user: user, company: company) }

    it "shows a refund badge and 'do not ship' for a fully-refunded item" do
      pkg = create(:package, shopify_store: store, aasm_state: "pending_review", number: 501)
      create(:package_item, package: pkg, sku: "WP-1", quantity: 2, refunded_quantity: 2)
      sign_in user
      get packages_path(state: "pending_review")
      expect(response.body).to include(CGI.escapeHTML(I18n.t("packages.do_not_ship")))
      expect(response.body).to include("2/2")
    end

    it "shows a partial refund badge without do-not-ship" do
      pkg = create(:package, shopify_store: store, aasm_state: "pending_review", number: 502)
      create(:package_item, package: pkg, sku: "WP-1", quantity: 3, refunded_quantity: 1)
      sign_in user
      get packages_path(state: "pending_review")
      expect(response.body).to include("1/3")
      expect(response.body).not_to include(CGI.escapeHTML(I18n.t("packages.do_not_ship")))
    end
  end

  describe "POST /packages/sync" do
    it "enqueues a sync job for the selected store and redirects with a notice" do
      store # ensure exists

      expect {
        post sync_packages_path
      }.to have_enqueued_job(SyncAllShopifyOrdersJob).with(store.id)

      expect(response).to redirect_to(packages_path)
      follow_redirect!
      expect(response.body).to include(I18n.t("packages.sync_enqueued"))
    end

    it "denies a member without any packing permission" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "orders" ])
      sign_out user
      sign_in member

      post sync_packages_path
      expect(response).to redirect_to(authenticated_root_path)
    end
  end
end
