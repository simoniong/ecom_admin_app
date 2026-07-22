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

  describe "destination country on the list reflects a manual address override" do
    def flag_for(code)
      code.each_char.map { |c| (c.ord + 127397).chr(Encoding::UTF_8) }.join
    end

    it "shows the snapshot's country (not the raw Shopify country) once the address is overridden" do
      order = create(:order, customer: customer, shopify_store: store, name: "PKS#7001",
                      shopify_data: { "shipping_address" => { "country_code" => "US" } })
      create(:package, shopify_store: store, order: order, aasm_state: "pending_review", number: 701,
             address_overridden: true, shipping_address_snapshot: { "country_code" => "JP" })

      get packages_path(state: "pending_review")

      expect(response.body).to include(flag_for("JP"))
      expect(response.body).not_to include(flag_for("US"))
    end

    it "falls back to the raw Shopify country when the snapshot has none" do
      order = create(:order, customer: customer, shopify_store: store, name: "PKS#7002",
                      shopify_data: { "shipping_address" => { "country_code" => "US" } })
      create(:package, shopify_store: store, order: order, aasm_state: "pending_review", number: 702,
             shipping_address_snapshot: {})

      get packages_path(state: "pending_review")

      expect(response.body).to include(flag_for("US"))
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

  describe "GET /packages/:id (detail)" do
    it "renders the package detail for a user with a packing permission" do
      order = create(:order, customer: customer, shopify_store: store, name: "PKS#3010")
      pkg = create(:package, shopify_store: store, order: order, aasm_state: "pending_process", number: 30)

      get package_path(id: pkg.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(pkg.package_code)
    end

    it "renders each read-only section with its stable dom id" do
      order = create(:order, customer: customer, shopify_store: store, name: "PKS#3011")
      pkg = create(:package, shopify_store: store, order: order, aasm_state: "pending_review", number: 31,
                    shipping_address_snapshot: { "name" => "Jane Doe", "country_code" => "US", "address1" => "1 Main St", "city" => "Springfield" },
                    note: "Handle with care")
      create(:package_item, package: pkg, sku: "SKU-DETAIL", title: "Widget", quantity: 2)

      get package_path(id: pkg.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(pkg, :address))
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(pkg, :customs))
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(pkg, :logistics))
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(pkg, :note))
      expect(response.body).to include("Jane Doe")
      expect(response.body).to include("Handle with care")
      expect(response.body).to include("SKU-DETAIL")
    end

    it "responds to a Turbo Frame request by rendering only the modal partial (no full layout chrome)" do
      order = create(:order, customer: customer, shopify_store: store, name: "PKS#3012")
      pkg = create(:package, shopify_store: store, order: order, aasm_state: "pending_review", number: 32)

      get package_path(id: pkg.id), headers: { "Turbo-Frame" => "package-modal" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(pkg.package_code)
      expect(response.body).not_to include("<!DOCTYPE html>")
    end

    it "does not leak another company's package" do
      other_user = create(:user)
      other_company = other_user.companies.first
      other_store = create(:shopify_store, user: other_user, company: other_company)
      other_customer = create(:customer, shopify_store: other_store)
      other_order = create(:order, customer: other_customer, shopify_store: other_store, name: "OTHER#3099")
      foreign = create(:package, shopify_store: other_store, order: other_order, aasm_state: "pending_review", number: 99)

      get package_path(id: foreign.id)

      expect(response).to have_http_status(:not_found)
    end

    it "denies a member without any packing permission" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "orders" ])
      sign_out user
      sign_in member
      order = create(:order, customer: customer, shopify_store: store, name: "PKS#3013")
      pkg = create(:package, shopify_store: store, order: order, aasm_state: "pending_review", number: 33)

      get package_path(id: pkg.id)

      expect(response).to redirect_to(authenticated_root_path)
    end
  end

  describe "PATCH /packages/:id/transition" do
    def sign_in_as_member_with(permission)
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ permission ])
      sign_out user
      sign_in member
      member
    end

    describe "review gate (submit_review / back_to_review)" do
      it "lets a member with package_review submit_review, advancing pending_review -> pending_process" do
        sign_in_as_member_with("package_review")

        patch transition_package_path(id: review_package.id, event: "submit_review")

        expect(review_package.reload.aasm_state).to eq("pending_process")
      end

      it "re-renders the modal via turbo_stream, reflecting the new state" do
        sign_in_as_member_with("package_review")

        patch transition_package_path(id: review_package.id, event: "submit_review"),
              headers: { "Accept" => "text/vnd.turbo-stream.html" }

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
        expect(response.body).to include("turbo-stream")
        expect(response.body).to include(I18n.t("packages.states.pending_process"))
      end

      it "denies a member with only package_process (redirect, no_permission), and does not transition" do
        sign_in_as_member_with("package_process")

        patch transition_package_path(id: review_package.id, event: "submit_review")

        expect(response).to redirect_to(packages_path)
        follow_redirect!
        expect(response.body).to include(CGI.escapeHTML(I18n.t("companies.no_permission")))
        expect(review_package.reload.aasm_state).to eq("pending_review")
      end

      it "lets a member with package_review back_to_review, reverting pending_process -> pending_review" do
        sign_in_as_member_with("package_review")

        patch transition_package_path(id: process_package.id, event: "back_to_review")

        expect(process_package.reload.aasm_state).to eq("pending_review")
      end
    end

    describe "process gate (hold / unhold / back_to_process)" do
      it "lets a member with package_process hold a package, capturing held_from" do
        sign_in_as_member_with("package_process")

        patch transition_package_path(id: review_package.id, event: "hold")

        review_package.reload
        expect(review_package.aasm_state).to eq("held")
        expect(review_package.held_from).to eq("pending_review")
      end

      it "denies a member with only package_review (redirect, no_permission), and does not transition" do
        sign_in_as_member_with("package_review")

        patch transition_package_path(id: review_package.id, event: "hold")

        expect(response).to redirect_to(packages_path)
        follow_redirect!
        expect(response.body).to include(CGI.escapeHTML(I18n.t("companies.no_permission")))
        expect(review_package.reload.aasm_state).to eq("pending_review")
      end

      it "restores a held package to its original state on unhold" do
        sign_in_as_member_with("package_process")
        held_package = create(:package, shopify_store: store, order: create(:order, customer: customer, shopify_store: store, name: "PKS#4001"),
                               aasm_state: "held", held_from: "pending_process", number: 40)

        patch transition_package_path(id: held_package.id, event: "unhold")

        held_package.reload
        expect(held_package.aasm_state).to eq("pending_process")
        expect(held_package.held_from).to be_nil  # cleared and persisted (update_column)
      end
    end

    describe "invalid transitions/events do not 500" do
      it "rejects an unlisted/bogus event name with an alert, not a 500" do
        sign_in_as_member_with("package_review")

        patch transition_package_path(id: review_package.id, event: "launch_rocket")

        expect(response).to redirect_to(packages_path)
        follow_redirect!
        expect(response.body).to include(I18n.t("packages.invalid_action"))
      end

      it "rejects an AASM-invalid event for the package's current state (ship from pending_review), not a 500" do
        sign_in_as_member_with("package_process")

        patch transition_package_path(id: review_package.id, event: "back_to_process")

        expect(response).not_to have_http_status(:internal_server_error)
        expect(review_package.reload.aasm_state).to eq("pending_review")
      end

      it "returns 422 with the re-rendered modal on turbo_stream for an AASM::InvalidTransition" do
        sign_in_as_member_with("package_process")

        patch transition_package_path(id: review_package.id, event: "back_to_process"),
              headers: { "Accept" => "text/vnd.turbo-stream.html" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("package-modal")
      end
    end
  end

  describe "PATCH /packages/:id/update_address" do
    def sign_in_as_member_with(permission)
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ permission ])
      sign_out user
      sign_in member
      member
    end

    let(:address_params) do
      {
        name: "Jane Doe", phone: "555-1234", address1: "1 Main St", address2: "Apt 2",
        city: "Springfield", province: "IL", zip: "62704", country: "United States",
        country_code: "US", company: "Acme Inc", tax_id: "TX-123"
      }
    end

    it "lets a member with package_process persist the snapshot and set address_overridden" do
      sign_in_as_member_with("package_process")

      patch update_address_package_path(id: review_package.id), params: { address: address_params }

      review_package.reload
      expect(review_package.address_overridden).to be(true)
      expect(review_package.shipping_address_snapshot["name"]).to eq("Jane Doe")
      expect(review_package.shipping_address_snapshot["address1"]).to eq("1 Main St")
      expect(review_package.shipping_address_snapshot["city"]).to eq("Springfield")
      expect(review_package.shipping_address_snapshot["country_code"]).to eq("US")
      expect(review_package.shipping_address_snapshot["tax_id"]).to eq("TX-123")
    end

    it "re-renders the address section via turbo_stream with the new values" do
      sign_in_as_member_with("package_process")

      patch update_address_package_path(id: review_package.id), params: { address: address_params },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(review_package, :address))
      expect(response.body).to include("Jane Doe")
    end

    it "also refreshes the tab strips and readiness panel in the same turbo_stream" do
      sign_in_as_member_with("package_process")

      patch update_address_package_path(id: review_package.id), params: { address: address_params },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(review_package, :tab_strip_mobile))
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(review_package, :tab_strip_desktop))
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(review_package, :readiness))
    end

    it "redirects with a notice on a plain HTML request" do
      sign_in_as_member_with("package_process")

      patch update_address_package_path(id: review_package.id), params: { address: address_params }

      expect(response).to redirect_to(package_path(id: review_package.id))
      follow_redirect!
      expect(response.body).to include(I18n.t("packages.address_saved"))
    end

    it "saves a partial address without enforcing required-together fields" do
      sign_in_as_member_with("package_process")

      patch update_address_package_path(id: review_package.id), params: { address: { name: "Only Name" } }

      review_package.reload
      expect(review_package.address_overridden).to be(true)
      expect(review_package.shipping_address_snapshot["name"]).to eq("Only Name")
      expect(review_package.shipping_address_snapshot["city"]).to eq("")
    end

    it "denies a member with only package_review (redirect, no_permission), and does not persist" do
      sign_in_as_member_with("package_review")

      patch update_address_package_path(id: review_package.id), params: { address: address_params }

      expect(response).to redirect_to(packages_path)
      follow_redirect!
      expect(response.body).to include(CGI.escapeHTML(I18n.t("companies.no_permission")))
      expect(review_package.reload.address_overridden).to be(false)
    end

    it "does not leak another company's package" do
      other_user = create(:user)
      other_company = other_user.companies.first
      other_store = create(:shopify_store, user: other_user, company: other_company)
      other_customer = create(:customer, shopify_store: other_store)
      other_order = create(:order, customer: other_customer, shopify_store: other_store, name: "OTHER#5001")
      foreign = create(:package, shopify_store: other_store, order: other_order, aasm_state: "pending_review", number: 50)

      patch update_address_package_path(id: foreign.id), params: { address: address_params }

      expect(response).to have_http_status(:not_found)
    end

    describe "integration with PackageAutoBuilder re-sync (proves the override flag wiring)" do
      it "preserves the manually-edited address after a later sync with different order data" do
        sign_in_as_member_with("package_process")
        order = review_package.order
        order.update!(shopify_data: order.shopify_data.merge(
          "shipping_address" => { "city" => "FROM_SHOPIFY", "name" => "Shopify Name" }
        ))

        patch update_address_package_path(id: review_package.id), params: { address: address_params }
        expect(review_package.reload.address_overridden).to be(true)

        order.update!(shopify_data: order.shopify_data.merge(
          "shipping_address" => { "city" => "DIFFERENT_CITY", "name" => "Different Name" }
        ))
        PackageAutoBuilder.new(order.reload).call

        review_package.reload
        expect(review_package.shipping_address_snapshot["city"]).to eq("Springfield")
        expect(review_package.shipping_address_snapshot["name"]).to eq("Jane Doe")
      end
    end
  end

  describe "PATCH /packages/:id/update_item" do
    def sign_in_as_member_with(permission)
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ permission ])
      sign_out user
      sign_in member
      member
    end

    let!(:item) { create(:package_item, package: review_package, sku: "SKU-EDIT", title: "Editable Widget", quantity: 2) }

    let(:customs_params) do
      {
        customs_name_zh: "小工具", customs_name_en: "Widget",
        declared_value_usd: "12.50", customs_weight_grams: "150",
        hs_code: "1234.56", import_hs_code: "9876.54"
      }
    end

    it "lets a member with package_process persist the 6 customs fields and set customs_overridden" do
      sign_in_as_member_with("package_process")

      patch update_item_package_path(id: review_package.id, item_id: item.id), params: { package_item: customs_params }

      item.reload
      expect(item.customs_overridden).to be(true)
      expect(item.customs_name_zh).to eq("小工具")
      expect(item.customs_name_en).to eq("Widget")
      expect(item.declared_value_usd).to eq(12.50)
      expect(item.customs_weight_grams).to eq(150)
      expect(item.hs_code).to eq("1234.56")
      expect(item.import_hs_code).to eq("9876.54")
    end

    it "re-renders the item's row via turbo_stream with the new values" do
      sign_in_as_member_with("package_process")

      patch update_item_package_path(id: review_package.id, item_id: item.id),
            params: { package_item: customs_params },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(item))
      expect(response.body).to include("Widget")
    end

    it "redirects with a notice on a plain HTML request" do
      sign_in_as_member_with("package_process")

      patch update_item_package_path(id: review_package.id, item_id: item.id), params: { package_item: customs_params }

      expect(response).to redirect_to(package_path(id: review_package.id))
      follow_redirect!
      expect(response.body).to include(I18n.t("packages.item_saved"))
    end

    it "saves a partial customs edit without enforcing required-together fields" do
      sign_in_as_member_with("package_process")

      patch update_item_package_path(id: review_package.id, item_id: item.id),
            params: { package_item: { customs_name_zh: "只有中文名" } }

      item.reload
      expect(item.customs_overridden).to be(true)
      expect(item.customs_name_zh).to eq("只有中文名")
      expect(item.customs_name_en).to be_nil
    end

    it "rejects a negative declared value with 422 (re-renders the row) instead of 500ing, and does not persist" do
      sign_in_as_member_with("package_process")

      patch update_item_package_path(id: review_package.id, item_id: item.id),
            params: { package_item: customs_params.merge(declared_value_usd: "-1") },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(item))
      item.reload
      expect(item.declared_value_usd).to be_nil
      expect(item.customs_overridden).to be(false)
    end

    it "refreshes the package-wide indicators (customs badge, tab strips, readiness) in the same successful stream" do
      sign_in_as_member_with("package_process")

      patch update_item_package_path(id: review_package.id, item_id: item.id),
            params: { package_item: customs_params },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(review_package, :customs_status))
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(review_package, :tab_strip_mobile))
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(review_package, :tab_strip_desktop))
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(review_package, :readiness))
    end

    it "does NOT refresh the package-wide indicators on a failed (422) save (DB unchanged)" do
      sign_in_as_member_with("package_process")

      patch update_item_package_path(id: review_package.id, item_id: item.id),
            params: { package_item: customs_params.merge(customs_weight_grams: "-5") },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).not_to include(ActionView::RecordIdentifier.dom_id(review_package, :readiness))
    end

    it "denies a member with only package_review (redirect, no_permission), and does not persist" do
      sign_in_as_member_with("package_review")

      patch update_item_package_path(id: review_package.id, item_id: item.id), params: { package_item: customs_params }

      expect(response).to redirect_to(packages_path)
      follow_redirect!
      expect(response.body).to include(CGI.escapeHTML(I18n.t("companies.no_permission")))
      expect(item.reload.customs_overridden).to be(false)
    end

    it "does not leak another package's item (scoped to @package.package_items)" do
      sign_in_as_member_with("package_process")
      foreign_item = create(:package_item, package: process_package, sku: "SKU-FOREIGN")

      patch update_item_package_path(id: review_package.id, item_id: foreign_item.id), params: { package_item: customs_params }

      expect(response).to have_http_status(:not_found)
      expect(foreign_item.reload.customs_overridden).to be(false)
    end

    it "does not leak another company's package" do
      other_user = create(:user)
      other_company = other_user.companies.first
      other_store = create(:shopify_store, user: other_user, company: other_company)
      other_customer = create(:customer, shopify_store: other_store)
      other_order = create(:order, customer: other_customer, shopify_store: other_store, name: "OTHER#6001")
      foreign_package = create(:package, shopify_store: other_store, order: other_order, aasm_state: "pending_review", number: 60)
      foreign_item = create(:package_item, package: foreign_package, sku: "SKU-OTHER")

      patch update_item_package_path(id: foreign_package.id, item_id: foreign_item.id), params: { package_item: customs_params }

      expect(response).to have_http_status(:not_found)
    end

    describe "integration with PackageAutoBuilder re-sync (proves the override flag wiring)" do
      it "preserves this item's manually-edited customs after a later sync with different variant customs" do
        sign_in_as_member_with("package_process")
        variant = create(:product_variant, product: create(:product, shopify_store: store),
                          customs_name_zh: "原廠中文", customs_name_en: "Factory Name",
                          declared_value_usd: 5.00, weight_grams: 100,
                          hs_code: "1111.11", import_hs_code: "2222.22")
        line_item = create(:order_line_item, order: review_package.order, product_variant: variant, quantity: 2)
        synced_item = create(:package_item, package: review_package, product_variant: variant,
                              order_line_item: line_item, sku: "SKU-SYNCED", quantity: 2)

        patch update_item_package_path(id: review_package.id, item_id: synced_item.id), params: { package_item: customs_params }
        expect(synced_item.reload.customs_overridden).to be(true)

        variant.update!(customs_name_zh: "CHANGED_ZH", customs_name_en: "CHANGED_EN",
                        declared_value_usd: 99.99, weight_grams: 999)
        PackageAutoBuilder.new(review_package.order.reload).call

        synced_item.reload
        expect(synced_item.customs_name_zh).to eq("小工具")
        expect(synced_item.customs_name_en).to eq("Widget")
        expect(synced_item.declared_value_usd).to eq(12.50)
        expect(synced_item.customs_weight_grams).to eq(150)
      end
    end
  end

  describe "PATCH /packages/:id/update_logistics" do
    def sign_in_as_member_with(permission)
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ permission ])
      sign_out user
      sign_in member
      member
    end

    let(:logistics_account) { create(:logistics_account, company: company) }
    let(:channel) { create(:logistics_channel, logistics_account: logistics_account, name: "DHL Express", product_shortname: "DHL") }

    it "assigns a company channel to the package" do
      sign_in_as_member_with("package_process")

      patch update_logistics_package_path(id: review_package.id), params: { logistics_channel_id: channel.id }

      expect(review_package.reload.logistics_channel_id).to eq(channel.id)
    end

    it "unassigns the channel when logistics_channel_id is blank" do
      sign_in_as_member_with("package_process")
      review_package.update!(logistics_channel_id: channel.id)

      patch update_logistics_package_path(id: review_package.id), params: { logistics_channel_id: "" }

      expect(review_package.reload.logistics_channel_id).to be_nil
    end

    it "refreshes the tab strips and readiness panel in the same turbo_stream (no modal reopen needed)" do
      sign_in_as_member_with("package_process")

      patch update_logistics_package_path(id: process_package.id), params: { logistics_channel_id: channel.id },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(process_package, :tab_strip_mobile))
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(process_package, :tab_strip_desktop))
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(process_package, :readiness))
    end

    it "re-renders the logistics section via turbo_stream with the new value" do
      sign_in_as_member_with("package_process")

      patch update_logistics_package_path(id: review_package.id), params: { logistics_channel_id: channel.id },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(review_package, :logistics))
      expect(response.body).to include("DHL Express")
    end

    it "redirects with a notice on a plain HTML request" do
      sign_in_as_member_with("package_process")

      patch update_logistics_package_path(id: review_package.id), params: { logistics_channel_id: channel.id }

      expect(response).to redirect_to(package_path(id: review_package.id))
      follow_redirect!
      expect(response.body).to include(I18n.t("packages.logistics_saved"))
    end

    it "rejects another company's channel id with an alert, and does not change logistics_channel_id" do
      sign_in_as_member_with("package_process")
      other_user = create(:user)
      other_company = other_user.companies.first
      other_account = create(:logistics_account, company: other_company)
      foreign_channel = create(:logistics_channel, logistics_account: other_account, name: "Foreign Channel")

      patch update_logistics_package_path(id: review_package.id), params: { logistics_channel_id: foreign_channel.id }

      expect(response).to redirect_to(package_path(id: review_package.id))
      follow_redirect!
      expect(response.body).to include(CGI.escapeHTML(I18n.t("packages.invalid_channel")))
      expect(review_package.reload.logistics_channel_id).to be_nil
    end

    it "leaves an existing assignment untouched when a foreign channel id is rejected" do
      sign_in_as_member_with("package_process")
      review_package.update!(logistics_channel_id: channel.id)
      other_user = create(:user)
      other_company = other_user.companies.first
      other_account = create(:logistics_account, company: other_company)
      foreign_channel = create(:logistics_channel, logistics_account: other_account, name: "Foreign Channel")

      patch update_logistics_package_path(id: review_package.id), params: { logistics_channel_id: foreign_channel.id }

      expect(review_package.reload.logistics_channel_id).to eq(channel.id)
    end

    it "denies a member with only package_review (redirect, no_permission), and does not persist" do
      sign_in_as_member_with("package_review")

      patch update_logistics_package_path(id: review_package.id), params: { logistics_channel_id: channel.id }

      expect(response).to redirect_to(packages_path)
      follow_redirect!
      expect(response.body).to include(CGI.escapeHTML(I18n.t("companies.no_permission")))
      expect(review_package.reload.logistics_channel_id).to be_nil
    end
  end

  describe "PATCH /packages/:id/update_note" do
    def sign_in_as_member_with(permission)
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ permission ])
      sign_out user
      sign_in member
      member
    end

    it "persists the note" do
      sign_in_as_member_with("package_process")

      patch update_note_package_path(id: review_package.id), params: { note: "Fragile — pack with care" }

      expect(review_package.reload.note).to eq("Fragile — pack with care")
    end

    it "re-renders the note section via turbo_stream with the new value" do
      sign_in_as_member_with("package_process")

      patch update_note_package_path(id: review_package.id), params: { note: "Fragile — pack with care" },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/vnd.turbo-stream.html")
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(review_package, :note))
      expect(response.body).to include("Fragile — pack with care")
    end

    it "redirects with a notice on a plain HTML request" do
      sign_in_as_member_with("package_process")

      patch update_note_package_path(id: review_package.id), params: { note: "Handle with care" }

      expect(response).to redirect_to(package_path(id: review_package.id))
      follow_redirect!
      expect(response.body).to include(I18n.t("packages.note_saved"))
    end

    it "denies a member with only package_review (redirect, no_permission), and does not persist" do
      sign_in_as_member_with("package_review")

      patch update_note_package_path(id: review_package.id), params: { note: "Should not save" }

      expect(response).to redirect_to(packages_path)
      follow_redirect!
      expect(response.body).to include(CGI.escapeHTML(I18n.t("companies.no_permission")))
      expect(review_package.reload.note).to be_nil
    end

    it "does not leak another company's package" do
      other_user = create(:user)
      other_company = other_user.companies.first
      other_store = create(:shopify_store, user: other_user, company: other_company)
      other_customer = create(:customer, shopify_store: other_store)
      other_order = create(:order, customer: other_customer, shopify_store: other_store, name: "OTHER#7001")
      foreign = create(:package, shopify_store: other_store, order: other_order, aasm_state: "pending_review", number: 70)

      patch update_note_package_path(id: foreign.id), params: { note: "Should not save" }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /packages/:id/split" do
    # PackageSplitter mints the new sibling's number from
    # package_number_seq || package_number_start — the shared `store` let
    # doesn't set either (packing_enabled is off by default), so seed a
    # sequence here the same way spec/services/package_splitter_spec.rb does.
    before { store.update_columns(package_number_start: 500_000, package_number_seq: 500_000) }

    let(:order) { create(:order, customer: customer, shopify_store: store, name: "PKS#SPLIT") }
    let(:oli)   { create(:order_line_item, order: order) }
    let!(:src) do
      pkg = create(:package, shopify_store: store, order: order, number: 500, aasm_state: "pending_process")
      create(:package_item, package: pkg, order_line_item: oli, sku: "A", quantity: 3)
      pkg
    end

    def sign_in_as_member_with(permission)
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ permission ])
      sign_out user
      sign_in member
      member
    end

    it "splits into a new sibling box and returns turbo_stream" do
      post split_package_path(id: src.id), params: { allocations: { oli.id => [ "1" ] } },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response).to have_http_status(:ok)
      expect(store.packages.where(order_id: order.id).count).to eq(2)
    end

    it "returns 422 (not 500) on an invalid allocation and persists nothing" do
      post split_package_path(id: src.id), params: { allocations: { oli.id => [ "0" ] } },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(store.packages.where(order_id: order.id).count).to eq(1)
    end

    it "rejects splitting a non-pending_process package" do
      src.update!(aasm_state: "pending_review")
      post split_package_path(id: src.id), params: { allocations: { oli.id => [ "1" ] } }
      expect(response).to have_http_status(:found) # redirect with alert
      expect(store.packages.where(order_id: order.id).count).to eq(1)
    end

    it "forbids a member without package_process permission" do
      sign_in_as_member_with("package_review")
      post split_package_path(id: src.id), params: { allocations: { oli.id => [ "1" ] } }
      expect(response).to have_http_status(:found)
      expect(store.packages.where(order_id: order.id).count).to eq(1)
    end

    it "404s for a package of another company" do
      stranger = create(:user)
      sign_in stranger
      post split_package_path(id: src.id), params: { allocations: { oli.id => [ "1" ] } }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /packages/:id/merge" do
    let(:order) { create(:order, customer: customer, shopify_store: store, name: "PKS#MERGE") }
    let(:oli)   { create(:order_line_item, order: order) }
    let!(:survivor) do
      pkg = create(:package, shopify_store: store, order: order, number: 600, aasm_state: "pending_process")
      create(:package_item, package: pkg, order_line_item: oli, sku: "A", quantity: 2)
      pkg
    end
    let!(:other) do
      pkg = create(:package, shopify_store: store, order: order, number: 601, aasm_state: "pending_process")
      create(:package_item, package: pkg, order_line_item: oli, sku: "A", quantity: 1)
      pkg
    end

    def sign_in_as_member_with(permission)
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ permission ])
      sign_out user
      sign_in member
      member
    end

    it "merges the order's boxes back into one and returns turbo_stream" do
      post merge_package_path(id: other.id),
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response).to have_http_status(:ok)
      expect(store.packages.where(order_id: order.id).count).to eq(1)
      expect(survivor.reload.package_items.find_by(order_line_item_id: oli.id).quantity).to eq(3)
    end

    it "forbids a member without package_process permission" do
      sign_in_as_member_with("package_review")
      post merge_package_path(id: other.id)
      expect(response).to have_http_status(:found)
      expect(store.packages.where(order_id: order.id).count).to eq(2)
    end

    it "rejects merging a non-pending_process package" do
      survivor.update!(aasm_state: "pending_review")
      post merge_package_path(id: survivor.id)
      expect(response).to have_http_status(:found) # redirect with alert
      expect(store.packages.where(order_id: order.id).count).to eq(2)
    end

    it "404s for a package of another company" do
      stranger = create(:user)
      sign_in stranger
      post merge_package_path(id: other.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "readiness + cancel display" do
    it "shows the logistics blocker for an incomplete pending_process package" do
      order = create(:order, customer: customer, shopify_store: store, name: "PKS#8001")
      pkg = create(:package, shopify_store: store, order: order, aasm_state: "pending_process", number: 80,
                    shipping_address_snapshot: {})
      create(:package_item, package: pkg, sku: "SKU-INCOMPLETE", title: "Widget", quantity: 1)

      get package_path(id: pkg.id), headers: { "Turbo-Frame" => "package-modal" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML(I18n.t("packages.blockers.logistics")))
    end

    it "shows the ready affordance (and not the blocked title) for a complete pending_process package" do
      logistics_account = create(:logistics_account, company: company)
      channel = create(:logistics_channel, logistics_account: logistics_account, name: "DHL Express", product_shortname: "DHL")
      order = create(:order, customer: customer, shopify_store: store, name: "PKS#8002")
      pkg = create(:package, shopify_store: store, order: order, aasm_state: "pending_process", number: 81,
                    logistics_channel: channel,
                    shipping_address_snapshot: { "name" => "Jane Doe", "country_code" => "US", "address1" => "1 Main St", "city" => "Springfield" })
      create(:package_item, package: pkg, sku: "SKU-COMPLETE", title: "Widget", quantity: 1,
             customs_name_zh: "小工具", customs_name_en: "Widget", declared_value_usd: 9.99, customs_weight_grams: 100)

      get package_path(id: pkg.id), headers: { "Turbo-Frame" => "package-modal" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML(I18n.t("packages.readiness.ready")))
      expect(response.body).not_to include(CGI.escapeHTML(I18n.t("packages.readiness.blocked_title")))
    end

    it "shows the cancelled-order badge on the list for a cancelled order" do
      order = create(:order, customer: customer, shopify_store: store, name: "PKS#8003",
                      shopify_data: { "cancelled_at" => "2026-07-20T00:00:00Z" }, financial_status: "paid")
      create(:package, shopify_store: store, order: order, aasm_state: "pending_review", number: 82)

      get packages_path(state: "pending_review")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML(I18n.t("packages.order_cancelled")))
    end

    it "does not show the blocked title for a non-pending_process package" do
      order = create(:order, customer: customer, shopify_store: store, name: "PKS#8004")
      pkg = create(:package, shopify_store: store, order: order, aasm_state: "pending_review", number: 83,
                    shipping_address_snapshot: {})

      get package_path(id: pkg.id), headers: { "Turbo-Frame" => "package-modal" }

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(CGI.escapeHTML(I18n.t("packages.readiness.blocked_title")))
    end
  end

  describe "tracking application" do
    def sign_in_as_member_with(permission)
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ permission ])
      sign_in member
    end

    let(:account) { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", customer_id: "1", customer_userid: "2") }
    let(:channel) { create(:logistics_channel, logistics_account: account, product_id: "P1") }

    # number: 700 is a fixed literal in the task brief's own helper; bumped to a
    # per-call counter here because "applies ready packages and skips not-ready
    # ones" below calls ready_pkg twice against the same store, and
    # Package#number is uniqueness-validated per shopify_store_id — the literal
    # collides on the second call (ActiveRecord::RecordInvalid) regardless of
    # controller behavior. No assertion anywhere depends on the number's value.
    def ready_pkg(state: "pending_process")
      @ready_pkg_number = (@ready_pkg_number || 699) + 1
      order = create(:order, customer: customer, shopify_store: store, name: "PKS#T1")
      pkg = create(:package, shopify_store: store, order: order, number: @ready_pkg_number, aasm_state: state, logistics_channel: channel,
                   shipping_address_snapshot: { "name" => "A", "address1" => "x", "city" => "P", "country_code" => "FR" })
      create(:package_item, package: pkg, order_line_item: create(:order_line_item, order: order), sku: "A", quantity: 1,
             customs_name_en: "Art", customs_name_zh: "画", declared_value_usd: 5, customs_weight_grams: 100)
      pkg
    end

    describe "POST /packages/:id/apply_tracking" do
      it "transitions to applying_tracking (pending) and enqueues the job" do
        pkg = ready_pkg
        expect {
          post apply_tracking_package_path(id: pkg.id), headers: { "Accept" => "text/vnd.turbo-stream.html" }
        }.to have_enqueued_job(ApplyTrackingJob).with(pkg.id)
        expect(response).to have_http_status(:ok)
        pkg.reload
        expect(pkg).to have_state(:applying_tracking)
        expect(pkg.application_status).to eq("pending")
      end

      it "rejects (422) a not-ready package with blockers, without transitioning" do
        pkg = ready_pkg
        pkg.update!(logistics_channel: nil) # not ready: no logistics
        post apply_tracking_package_path(id: pkg.id), headers: { "Accept" => "text/vnd.turbo-stream.html" }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(pkg.reload).to have_state(:pending_process)
      end

      it "rejects a non-pending_process package" do
        pkg = ready_pkg(state: "pending_review")
        post apply_tracking_package_path(id: pkg.id)
        expect(response).to have_http_status(:found)
        expect(pkg.reload).to have_state(:pending_review)
      end

      it "forbids a member without package_process" do
        pkg = ready_pkg
        sign_in_as_member_with("package_review")
        post apply_tracking_package_path(id: pkg.id)
        expect(response).to have_http_status(:found)
        expect(pkg.reload).to have_state(:pending_process)
      end

      it "404s for another company's package" do
        pkg = ready_pkg
        sign_in create(:user)
        post apply_tracking_package_path(id: pkg.id)
        expect(response).to have_http_status(:not_found)
      end
    end

    describe "POST /packages/:id/retry_tracking" do
      it "re-enqueues the job for a failed applying_tracking package" do
        pkg = ready_pkg(state: "applying_tracking")
        pkg.update!(application_status: "failed", application_message: "boom")
        expect {
          post retry_tracking_package_path(id: pkg.id), headers: { "Accept" => "text/vnd.turbo-stream.html" }
        }.to have_enqueued_job(ApplyTrackingJob).with(pkg.id)
        expect(pkg.reload.application_status).to eq("pending")
      end
    end

    describe "POST /packages/apply_tracking_bulk" do
      it "applies ready packages and skips not-ready ones" do
        ready = ready_pkg
        not_ready = ready_pkg
        not_ready.update!(logistics_channel: nil)
        expect {
          post apply_tracking_bulk_packages_path, params: { package_ids: [ ready.id, not_ready.id ] }
        }.to have_enqueued_job(ApplyTrackingJob).with(ready.id)
        expect(ready.reload).to have_state(:applying_tracking)
        expect(not_ready.reload).to have_state(:pending_process)
      end

      it "forbids a member without package_process" do
        pkg = ready_pkg
        sign_in_as_member_with("package_review")
        post apply_tracking_bulk_packages_path, params: { package_ids: [ pkg.id ] }
        expect(response).to have_http_status(:found)
        expect(pkg.reload).to have_state(:pending_process)
      end
    end
  end
end
