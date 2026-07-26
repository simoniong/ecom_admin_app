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

    it "hides the store filter row when only one store is visible" do
      get packages_path

      # A bare text match on "Store" would also catch the sidebar's "Shopify
      # Stores" nav link (always rendered for an owner membership), so this
      # scopes to the filter bar's own element instead.
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-testid='store-filter']")).to be_nil
    end

    describe "split badge" do
      let!(:split_boxes) do
        order = create(:order, customer: customer, shopify_store: store, name: "PKS#9001")
        [
          create(:package, shopify_store: store, order: order, aasm_state: "pending_review", number: 91),
          create(:package, shopify_store: store, order: order, aasm_state: "pending_review", number: 92)
        ]
      end

      it "marks each box of a split order with its position and total" do
        get packages_path

        expect(response.body).to include(I18n.t("packages.split.badge", position: 1, total: 2))
        expect(response.body).to include(I18n.t("packages.split.badge", position: 2, total: 2))
      end

      it "does not mark a package whose order has a single box" do
        split_boxes.last.destroy!

        get packages_path

        expect(response.body).not_to include(I18n.t("packages.split.badge", position: 1, total: 2))
      end

      it "marks split boxes on other state pages too" do
        split_boxes.each { |box| box.update!(aasm_state: "shipped") }

        get packages_path, params: { state: "shipped" }

        expect(response.body).to include(I18n.t("packages.split.badge", position: 2, total: 2))
      end

      it "gives every row a dom id so a turbo stream can target it" do
        get packages_path

        expect(response.body).to include("id=\"#{ActionView::RecordIdentifier.dom_id(split_boxes.first)}\"")
      end

      # The badge sits under the order number rather than beside the package
      # code: the order-number cell is single-line and has the vertical room to
      # spare, while widening the package-code cell costs horizontal space on an
      # already-wide table. Asserting the containing cell — not just presence
      # somewhere in the body — is what makes this a placement test.
      it "puts the badge in the same cell as the order number" do
        get packages_path

        row = Nokogiri::HTML(response.body)
                .at_css("tr##{ActionView::RecordIdentifier.dom_id(split_boxes.first)}")
        badge_text = I18n.t("packages.split.badge", position: 1, total: 2)
        order_cell = row.css("td").find { |td| td.text.include?(split_boxes.first.order.name) }

        expect(order_cell.text).to include(badge_text)
        package_code_cell = row.css("td").find { |td| td.text.include?(split_boxes.first.package_code) }
        expect(package_code_cell.text).not_to include(badge_text)
      end
    end

    describe "country filter and sorting" do
      let!(:us_package) do
        order = create(:order, customer: customer, shopify_store: store, name: "PKS#5001",
                       ordered_at: 5.days.ago, paid_at: 5.days.ago)
        create(:package, shopify_store: store, order: order, aasm_state: "pending_review",
               number: 51, created_at: 5.days.ago,
               shipping_address_snapshot: { "country_code" => "US" })
      end

      let!(:ca_package) do
        order = create(:order, customer: customer, shopify_store: store, name: "PKS#5002",
                       ordered_at: 1.hour.ago, paid_at: 1.hour.ago)
        create(:package, shopify_store: store, order: order, aasm_state: "pending_review",
               number: 52, created_at: 1.hour.ago,
               shipping_address_snapshot: { "country_code" => "CA" })
      end

      it "filters the list to the requested country" do
        get packages_path, params: { country: "US" }

        expect(response.body).to include("PKS#5001")
        expect(response.body).not_to include("PKS#5002")
      end

      it "ignores a country that is not present in the list" do
        get packages_path, params: { country: "JP" }

        expect(response.body).to include("PKS#5001")
        expect(response.body).to include("PKS#5002")
      end

      it "sorts by the order's ordered_at ascending" do
        get packages_path, params: { sort_column: "ordered_at", sort_direction: "asc" }

        expect(response.body.index("PKS#5001")).to be < response.body.index("PKS#5002")
      end

      it "sorts by the order's paid_at descending" do
        get packages_path, params: { sort_column: "paid_at", sort_direction: "desc" }

        expect(response.body.index("PKS#5002")).to be < response.body.index("PKS#5001")
      end

      it "falls back to the default sort for junk sort params" do
        get packages_path, params: { sort_column: "; drop table", sort_direction: "sideways" }

        expect(response).to have_http_status(:ok)
        expect(response.body.index("PKS#5002")).to be < response.body.index("PKS#5001")
      end
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

    describe "combined country filter + sort + pagination" do
      # Rails only takes the eager_load DISTINCT-id subquery path when
      # `includes` and `joins` overlap on the same association — exactly what
      # PackagesController#index does (includes(:order, ...) alongside
      # PackageListQuery's joins(:order)). That combination only actually
      # engages once a WHERE (country) and a non-default ORDER BY (sort) are
      # both in play at the same time as pagination's LIMIT/OFFSET, so this
      # spec exercises all three together rather than in isolation.
      let(:us_count) { PackagesController::PER_PAGE + 5 }

      let!(:us_combo_packages) do
        Array.new(us_count) do |i|
          order = create(:order, customer: customer, shopify_store: store, name: "PKS#COMBO-US-#{i}",
                         ordered_at: (us_count - i).days.ago)
          create(:package, shopify_store: store, order: order, aasm_state: "pending_review",
                 number: 3000 + i, shipping_address_snapshot: { "country_code" => "US" })
        end
      end

      let!(:ca_combo_packages) do
        Array.new(3) do |i|
          order = create(:order, customer: customer, shopify_store: store, name: "PKS#COMBO-CA-#{i}",
                         ordered_at: (i + 1).days.ago)
          create(:package, shopify_store: store, order: order, aasm_state: "pending_review",
                 number: 4000 + i, shipping_address_snapshot: { "country_code" => "CA" })
        end
      end

      def combo_us_names_in_order(body)
        body.scan(/PKS#COMBO-US-\d+/)
      end

      it "returns page 1 sorted ascending by ordered_at, scoped to the country filter" do
        get packages_path, params: { country: "US", sort_column: "ordered_at", sort_direction: "asc", page: 1 }

        expect(response).to have_http_status(:ok)
        expected = (0...PackagesController::PER_PAGE).map { |i| "PKS#COMBO-US-#{i}" }
        expect(combo_us_names_in_order(response.body)).to eq(expected)
        expect(response.body).not_to include("PKS#COMBO-CA")
      end

      it "returns the remainder on page 2, still ascending and still scoped to the country filter" do
        get packages_path, params: { country: "US", sort_column: "ordered_at", sort_direction: "asc", page: 2 }

        expect(response).to have_http_status(:ok)
        expected = (PackagesController::PER_PAGE...us_count).map { |i| "PKS#COMBO-US-#{i}" }
        expect(combo_us_names_in_order(response.body)).to eq(expected)
        expect(response.body).not_to include("PKS#COMBO-CA")
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

    describe "cross-store listing" do
      let(:other_store) { create(:shopify_store, user: user, company: company) }
      let(:other_customer) { create(:customer, shopify_store: other_store) }

      let!(:other_store_package) do
        order = create(:order, customer: other_customer, shopify_store: other_store, name: "PKS#6001")
        create(:package, shopify_store: other_store, order: order, aasm_state: "pending_review", number: 61)
      end

      it "lists packages from every visible store by default" do
        get packages_path

        expect(response.body).to include("PKS#1001")
        expect(response.body).to include("PKS#6001")
      end

      it "shows the store name in a pill instead of a column when no single store is selected" do
        get packages_path

        # A bare text match on "Store" would also catch the sidebar's "Shopify
        # Stores" nav link (always rendered for an owner membership), so this
        # scopes the column-removal check to the table header.
        doc = Nokogiri::HTML(response.body)
        expect(doc.css("thead th").map(&:text)).not_to include(I18n.t("packages.columns.store"))
        expect(response.body).to include(other_store.display_name)
      end

      it "narrows to one store when the store param is given" do
        get packages_path, params: { store: store.id }

        expect(response.body).to include("PKS#1001")
        expect(response.body).not_to include("PKS#6001")
      end

      it "labels the timezone only when several stores share the list" do
        store.update!(timezone: "America/Los_Angeles")

        get packages_path
        multi_store_body = response.body

        # `store` (not the old store_id) is the param that drives this view now:
        # #selected_store reads only params[:store], and both show_zone and the
        # package list scoping read #selected_store.
        get packages_path, params: { store: store.id }
        single_store_body = response.body

        expect(multi_store_body).to include(Time.current.in_time_zone("America/Los_Angeles").zone)
        expect(single_store_body).not_to include(Time.current.in_time_zone("America/Los_Angeles").zone)

        # Narrowing to one store via `store` also narrows the package list
        # itself now that show_zone and the list scoping share #selected_store —
        # the other store's package is gone, not just unlabeled.
        expect(single_store_body).not_to include("PKS#6001")
      end
    end

    describe "store filter" do
      let(:other_store) { create(:shopify_store, user: user, company: company) }
      let(:other_customer) { create(:customer, shopify_store: other_store) }

      let!(:other_store_package) do
        order = create(:order, customer: other_customer, shopify_store: other_store, name: "PKS#7701")
        create(:package, shopify_store: other_store, order: order, aasm_state: "pending_review", number: 77)
      end

      it "lists every visible store by default" do
        get packages_path

        expect(response.body).to include("PKS#1001")
        expect(response.body).to include("PKS#7701")
      end

      it "narrows to the store named by the store param" do
        get packages_path, params: { store: other_store.id }

        expect(response.body).to include("PKS#7701")
        expect(response.body).not_to include("PKS#1001")
      end

      it "falls back to every store for an unknown store id" do
        get packages_path, params: { store: SecureRandom.uuid }

        expect(response.body).to include("PKS#1001")
        expect(response.body).to include("PKS#7701")
      end

      it "ignores a store belonging to another company" do
        foreign_user = create(:user)
        foreign_store = create(:shopify_store, user: foreign_user, company: foreign_user.companies.first)

        get packages_path, params: { store: foreign_store.id }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("PKS#1001")
        expect(response.body).to include("PKS#7701")
      end

      # The whole point of moving off the global switcher: selecting a store here
      # must not follow the user to the orders page.
      it "does not write the selection into the session" do
        get packages_path, params: { store: other_store.id }

        expect(session[:store_id]).to be_nil
      end

      it "renders a pill for every visible store" do
        get packages_path

        expect(response.body).to include(I18n.t("packages.filters.store"))
        expect(response.body).to include(store.display_name)
        expect(response.body).to include(other_store.display_name)
      end

      it "drops the store column from the table" do
        get packages_path

        # A bare text match on "Store" would also catch the sidebar's "Shopify
        # Stores" nav link (always rendered for an owner membership), so this
        # scopes the check to the table header.
        doc = Nokogiri::HTML(response.body)
        expect(doc.css("thead th").map(&:text)).not_to include(I18n.t("packages.columns.store"))
      end

      it "keeps the header and body cell counts in agreement" do
        get packages_path

        doc = Nokogiri::HTML(response.body)
        header_cells = doc.css("thead th").size
        body_cells = doc.css("tbody tr").first.css("td").size

        expect(body_cells).to eq(header_cells)
      end
    end

    describe "store switcher scoping" do
      # Task 2: the packing list no longer participates in the global store
      # switcher (packages is absent from STORE_SWITCHER_CONTROLLERS) — it
      # owns its own store filter via params[:store]/#selected_store instead.
      # The list + sidebar counts follow #selected_store: nil (no store
      # param, or one that resolves to nothing) aggregates every visible
      # store; a store id narrows to just that store. Nothing here is ever
      # persisted to session[:store_id], so a selection can't leak into
      # another page (see the "store filter" examples above for that).
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

      it "defaults to an aggregate of every visible store when none is explicitly selected" do
        # No store param, #selected_store resolves to nil — scoped_packages'
        # nil branch then aggregates every visible store's packages, and the
        # sidebar badge counts follow the same scope.
        get packages_path
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("PKS#1001")
        expect(response.body).to include("PKS#STOREB")
        expect(sidebar_badge_count(response.body, "Pending Review")).to eq(2)
      end

      it "scopes the list and sidebar counts to the selected store" do
        get packages_path, params: { store: store.id }
        expect(response.body).to include("PKS#1001")
        expect(response.body).not_to include("PKS#STOREB")
        expect(sidebar_badge_count(response.body, "Pending Review")).to eq(1)
      end

      # This intentionally replaces the old "adds packages to
      # STORE_SWITCHER_CONTROLLERS so the switcher persists a selection"
      # example: that assertion (session[:store_id] set from a packages-page
      # request) is exactly the cross-page leak this task removes. See the
      # "store filter" describe above for the "does not write the selection
      # into the session" coverage that replaces it.
      it "does not add packages back to the global store switcher" do
        get packages_path, params: { store: store_b.id }
        expect(session[:store_id]).to be_nil

        get packages_path
        expect(response.body).to include("PKS#1001")
        expect(response.body).to include("PKS#STOREB")
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

      it "never leaks another company's package even when its store param is passed explicitly" do
        other_user = create(:user)
        other_company = other_user.companies.first
        other_store = create(:shopify_store, user: other_user, company: other_company)
        other_customer = create(:customer, shopify_store: other_store)
        other_order = create(:order, customer: other_customer, shopify_store: other_store, name: "OTHER#8888")
        create(:package, shopify_store: other_store, order: other_order, aasm_state: "pending_review", number: 1)

        # #selected_store resolves params[:store] against visible_shopify_stores
        # (scoped to the current company), so a foreign store id can never
        # select a foreign store — it falls back to every visible store.
        get packages_path, params: { store: other_store.id }
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

    it "streams a modal dismissal alongside the replaced row" do
      post split_package_path(id: src.id), params: { allocations: { oli.id => [ "1" ] } },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response.body).to include('action="dismiss_modal"')
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(src))
    end

    it "leaves the modal open with the error banner on an invalid allocation" do
      post split_package_path(id: src.id), params: { allocations: { oli.id => [ "0" ] } },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).not_to include('action="dismiss_modal"')
      # allocations: { oli.id => ["0"] } allocates nothing to box 1 while the
      # source keeps its full shippable quantity, so PackageSplitter's
      # validator returns exactly [:empty_box] — this is what the modal's
      # error banner (_split_dialog.html.erb) actually renders from
      # @split_errors. Asserting on the translated text (not just the status
      # + absence of dismiss_modal) is what would have caught a deleted
      # `turbo_stream.replace "package-modal"` line in the failure branch —
      # that regression left this example green before this assertion existed.
      expect(response.body).to include(I18n.t("packages.split.errors.empty_box"))
    end

    it "rejects splitting a non-pending_process package" do
      src.update!(aasm_state: "pending_review")
      post split_package_path(id: src.id), params: { allocations: { oli.id => [ "1" ] } }
      expect(response).to have_http_status(:found) # redirect with alert
      expect(store.packages.where(order_id: order.id).count).to eq(1)
    end

    it "rejects a second split of an already-split package and mints no third box" do
      # First split succeeds and stays pending_process (still eligible on the
      # pending_process? check alone) — the _split_dialog partial already
      # hides the button once package.split? is true, but nothing before this
      # fix stopped a stale form (still open from before the first split
      # landed) from POSTing again anyway.
      post split_package_path(id: src.id), params: { allocations: { oli.id => [ "1" ] } },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
      expect(response).to have_http_status(:ok)
      expect(store.packages.where(order_id: order.id).count).to eq(2)

      post split_package_path(id: src.id), params: { allocations: { oli.id => [ "1" ] } }

      expect(response).to have_http_status(:found) # redirect with alert
      expect(response).to redirect_to(package_path(id: src.id))
      expect(store.packages.where(order_id: order.id).count).to eq(2) # no third box
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

    describe "from the standalone show page (context=standalone)" do
      # _split_dialog only renders this hidden field when show.html.erb
      # rendered the modal with standalone: true — see that view and
      # _split_dialog.html.erb. A request carrying it is exactly what the
      # standalone page's own form submits; nothing here is inferred from
      # the referer.
      it "navigates the whole page back to the list instead of dismissing a (non-existent) modal" do
        post split_package_path(id: src.id),
             params: { allocations: { oli.id => [ "1" ] }, context: "standalone" },
             headers: { "Accept" => "text/vnd.turbo-stream.html" }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('action="visit"')
        # state: pending_process (src's own, unchanged by the split) — not the
        # bare list URL — so the operator lands where the new boxes actually
        # render, not the default pending_review list.
        expect(response.body).to include(packages_path(state: "pending_process"))
        expect(response.body).not_to include('action="dismiss_modal"')
      end

      it "keeps the list-page path unchanged when context is absent" do
        post split_package_path(id: src.id), params: { allocations: { oli.id => [ "1" ] } },
             headers: { "Accept" => "text/vnd.turbo-stream.html" }

        expect(response.body).to include('action="dismiss_modal"')
        expect(response.body).not_to include('action="visit"')
      end
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

    it "streams a modal dismissal and removes the absorbed row" do
      post merge_package_path(id: other.id),
           headers: { "Accept" => "text/vnd.turbo-stream.html" }

      expect(response.body).to include('action="dismiss_modal"')
      expect(response.body).to include('action="remove"')
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(other))
      expect(response.body).to include(ActionView::RecordIdentifier.dom_id(survivor))
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

    describe "from the standalone show page (context=standalone)" do
      # _siblings_strip only sends context=standalone as an extra hidden field
      # on the merge button_to form when show.html.erb rendered the modal with
      # standalone: true — see that view and _siblings_strip.html.erb. A
      # request carrying it is exactly what the standalone page's own button
      # submits; nothing here is inferred from the referer.
      it "navigates the whole page back to the list instead of streaming row updates" do
        post merge_package_path(id: other.id),
             params: { context: "standalone" },
             headers: { "Accept" => "text/vnd.turbo-stream.html" }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include('action="visit"')
        # state: pending_process (the survivor's own, unchanged by a merge) —
        # not the bare list URL — so the operator lands where the collapsed
        # box actually renders, not the default pending_review list.
        expect(response.body).to include(packages_path(state: "pending_process"))
        expect(response.body).not_to include('action="dismiss_modal"')
        expect(response.body).not_to include('action="remove"')
      end

      it "keeps streaming the row replace and removals when context is absent" do
        post merge_package_path(id: other.id),
             headers: { "Accept" => "text/vnd.turbo-stream.html" }

        expect(response.body).to include('action="dismiss_modal"')
        expect(response.body).to include('action="remove"')
        expect(response.body).not_to include('action="visit"')
      end
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

      # Guards the per-package rescue in apply_tracking_bulk: a raised
      # AASM::InvalidTransition on one package (e.g. a concurrent state change
      # between the scope query and the apply_tracking! bang) must not abort
      # find_each mid-batch. Forcing that raise directly would require a race
      # that's infeasible to set up deterministically in a request spec, so
      # this instead proves the loop-completion contract the rescue exists to
      # protect: with multiple ready pending_process packages, EVERY one is
      # transitioned and enqueued — not just the first — i.e. the loop runs to
      # completion rather than stopping after one iteration.
      it "processes every ready package in the batch, not just the first" do
        first = ready_pkg
        second = ready_pkg
        expect {
          post apply_tracking_bulk_packages_path, params: { package_ids: [ first.id, second.id ] }
        }.to have_enqueued_job(ApplyTrackingJob).with(first.id)
         .and have_enqueued_job(ApplyTrackingJob).with(second.id)
        expect(first.reload).to have_state(:applying_tracking)
        expect(second.reload).to have_state(:applying_tracking)
      end

      it "carries the current filters back to the list" do
        post apply_tracking_bulk_packages_path,
             params: { package_ids: [ process_package.id ], country: "US", sort_column: "ordered_at" }

        expect(response).to redirect_to(
          packages_path(country: "US", sort_column: "ordered_at", state: "pending_process")
        )
      end
    end
  end

  describe "label printing" do
    def sign_in_as_member_with(permission)
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ permission ])
      sign_in member
    end

    let(:account) { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", url2_base: "http://raydo.test:8089", customer_id: "1", customer_userid: "2") }
    let(:channel) { create(:logistics_channel, logistics_account: account, product_id: "P1", label_print_type: "lab10_10") }

    def label_pkg(number: 900, order_id: "R900", chan: channel, state: "pending_label")
      order = create(:order, customer: customer, shopify_store: store, name: "PKS#L#{number}")
      create(:package, shopify_store: store, order: order, number: number, aasm_state: state, logistics_channel: chan, raydo_order_id: order_id)
    end

    def stub_label(order_ids: "R900", type: "lab10_10")
      stub_request(:get, "http://raydo.test:8089/order/FastRpt/PDF_NEW.aspx").
        with(query: { "PrintType" => type, "order_id" => order_ids }).
        to_return(body: "%PDF-1.4\nlabel", headers: { "Content-Type" => "application/pdf" })
    end

    describe "GET /packages/:id/label" do
      it "streams the label PDF inline" do
        pkg = label_pkg
        stub_label(order_ids: pkg.raydo_order_id)
        get label_package_path(id: pkg.id)
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("application/pdf")
        expect(response.headers["Content-Disposition"]).to include("inline")
        expect(response.body).to start_with("%PDF")
      end

      it "redirects with an alert when Raydo errors" do
        pkg = label_pkg
        stub_request(:get, "http://raydo.test:8089/order/FastRpt/PDF_NEW.aspx").with(query: hash_including({})).to_return(status: 500, body: "e")
        get label_package_path(id: pkg.id)
        expect(response).to have_http_status(:found)
        # The stub's raw carrier body is a single-char string ("e"), too
        # generic to assert not_to include against an English error message —
        # asserting the exact generic message is what actually proves the raw
        # carrier string never reached the flash (a raw "e" surfacing would
        # fail this eq check, since it wouldn't match the full sentence).
        expect(flash[:alert]).to eq(I18n.t("packages.label.errors.failed"))
      end

      it "redirects for a non-pending_label package" do
        pkg = label_pkg(state: "pending_process")
        get label_package_path(id: pkg.id)
        expect(response).to have_http_status(:found)
      end

      it "forbids a member without package_shipping" do
        pkg = label_pkg
        sign_in_as_member_with("package_process")
        get label_package_path(id: pkg.id)
        expect(response).to have_http_status(:found)
      end

      it "404s for another company's package" do
        pkg = label_pkg
        sign_in create(:user)
        get label_package_path(id: pkg.id)
        expect(response).to have_http_status(:not_found)
      end
    end

    describe "POST /packages/labels" do
      it "streams a combined PDF for same-type packages" do
        a = label_pkg(number: 901, order_id: "R901")
        b = label_pkg(number: 902, order_id: "R902")
        stub_label(order_ids: "R901,R902")
        post labels_packages_path, params: { package_ids: [ a.id, b.id ] }
        expect(response.media_type).to eq("application/pdf")
        expect(response.body).to start_with("%PDF")
      end

      it "redirects with alert on mixed label types" do
        other = create(:logistics_channel, logistics_account: account, product_id: "P2", label_print_type: "A4")
        a = label_pkg(number: 901, order_id: "R901")
        b = label_pkg(number: 902, order_id: "R902", chan: other)
        post labels_packages_path, params: { package_ids: [ a.id, b.id ] }
        expect(response).to have_http_status(:found)
      end

      it "forbids a member without package_shipping" do
        pkg = label_pkg
        sign_in_as_member_with("package_process")
        post labels_packages_path, params: { package_ids: [ pkg.id ] }
        expect(response).to have_http_status(:found)
      end
    end
  end

  describe "shipping" do
    def sign_in_as_member_with(permission)
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ permission ])
      sign_in member
    end

    let(:account) { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082", url2_base: "http://raydo.test:8089", customer_id: "6581", customer_userid: "6901") }
    let(:channel) { create(:logistics_channel, logistics_account: account, product_id: "P1") }

    def pl_pkg(number: 900, state: "pending_label", tn: "TN900")
      order = create(:order, customer: customer, shopify_store: store, name: "PKS#S#{number}")
      create(:package, shopify_store: store, order: order, number: number, aasm_state: state, logistics_channel: channel, raydo_order_id: "R#{number}", tracking_number: tn)
    end

    describe "POST /packages/:id/ship" do
      it "ships + enqueues sync when the store toggle is ON" do
        store.update!(shipping_sync_enabled: true)
        pkg = pl_pkg
        expect { post ship_package_path(id: pkg.id), headers: { "Accept" => "text/vnd.turbo-stream.html" } }
          .to have_enqueued_job(PackageShipSyncJob).with(pkg.id)
        pkg.reload
        expect(pkg).to have_state(:shipped)
        expect(pkg.ship_sync_status).to eq("pending")
      end

      it "ships WITHOUT sync when the toggle is OFF (test mode)" do
        store.update!(shipping_sync_enabled: false)
        pkg = pl_pkg
        expect { post ship_package_path(id: pkg.id) }.not_to have_enqueued_job(PackageShipSyncJob)
        pkg.reload
        expect(pkg).to have_state(:shipped)
        expect(pkg.ship_sync_status).to eq("none")
      end

      it "rejects (422/redirect) shipping without a tracking number" do
        pkg = pl_pkg(tn: nil)
        post ship_package_path(id: pkg.id)
        expect(pkg.reload).to have_state(:pending_label)
      end

      it "rejects a non-pending_label package" do
        pkg = pl_pkg(state: "shipped")
        post ship_package_path(id: pkg.id)
        expect(response).to have_http_status(:found)
      end

      it "forbids a member without package_shipping" do
        pkg = pl_pkg
        sign_in_as_member_with("package_process")
        post ship_package_path(id: pkg.id)
        expect(pkg.reload).to have_state(:pending_label)
      end

      it "404s for another company's package" do
        pkg = pl_pkg
        sign_in create(:user)
        post ship_package_path(id: pkg.id)
        expect(response).to have_http_status(:not_found)
      end
    end

    describe "POST /packages/:id/sync_shipment" do
      it "re-enqueues for a failed shipped package when toggle ON" do
        store.update!(shipping_sync_enabled: true)
        pkg = pl_pkg(state: "shipped")
        pkg.update!(ship_sync_status: "failed")
        expect { post sync_shipment_package_path(id: pkg.id) }.to have_enqueued_job(PackageShipSyncJob).with(pkg.id)
        expect(pkg.reload.ship_sync_status).to eq("pending")
      end

      it "rejects when the store toggle is OFF" do
        pkg = pl_pkg(state: "shipped")
        pkg.update!(ship_sync_status: "none")
        post sync_shipment_package_path(id: pkg.id)
        expect(response).to have_http_status(:found)
      end
    end

    describe "POST /packages/ship_bulk" do
      it "ships selected pending_label packages" do
        store.update!(shipping_sync_enabled: false)
        a = pl_pkg(number: 901, tn: "T1")
        b = pl_pkg(number: 902, tn: "T2")
        post ship_bulk_packages_path, params: { package_ids: [ a.id, b.id ] }
        expect(a.reload).to have_state(:shipped)
        expect(b.reload).to have_state(:shipped)
      end

      it "carries the current filters back to the list" do
        post ship_bulk_packages_path,
             params: { package_ids: [], country: "US", sort_column: "ordered_at" }

        expect(response).to redirect_to(
          packages_path(country: "US", sort_column: "ordered_at", state: "pending_label")
        )
      end
    end
  end

  describe "POST /packages/submit_review_bulk" do
    def sign_in_as_member_with(permission)
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ permission ])
      sign_out user
      sign_in member
      member
    end

    it "advances every selected pending_review package" do
      second = create(:package, shopify_store: store, aasm_state: "pending_review", number: 81,
                      order: create(:order, customer: customer, shopify_store: store, name: "PKS#8001"))

      post submit_review_bulk_packages_path, params: { package_ids: [ review_package.id, second.id ] }

      expect(review_package.reload.aasm_state).to eq("pending_process")
      expect(second.reload.aasm_state).to eq("pending_process")
      expect(flash[:notice]).to include("2")
    end

    it "skips a package that is not pending_review" do
      post submit_review_bulk_packages_path, params: { package_ids: [ process_package.id ] }

      expect(process_package.reload.aasm_state).to eq("pending_process")
      expect(response).to redirect_to(packages_path(state: "pending_review"))
    end

    it "denies a member without package_review and transitions nothing" do
      sign_in_as_member_with("package_process")

      post submit_review_bulk_packages_path, params: { package_ids: [ review_package.id ] }

      expect(review_package.reload.aasm_state).to eq("pending_review")
      expect(response).to redirect_to(packages_path)
      expect(flash[:alert]).to eq(I18n.t("companies.no_permission"))
    end

    it "allows a member granted package_review" do
      sign_in_as_member_with("package_review")

      post submit_review_bulk_packages_path, params: { package_ids: [ review_package.id ] }

      expect(review_package.reload.aasm_state).to eq("pending_process")
    end

    it "ignores a package belonging to another company" do
      other_user = create(:user)
      other_store = create(:shopify_store, user: other_user, company: other_user.companies.first)
      other_customer = create(:customer, shopify_store: other_store)
      foreign = create(:package, shopify_store: other_store, aasm_state: "pending_review", number: 91,
                       order: create(:order, customer: other_customer, shopify_store: other_store))

      post submit_review_bulk_packages_path, params: { package_ids: [ foreign.id ] }

      expect(foreign.reload.aasm_state).to eq("pending_review")
    end

    it "advances a legitimate package while leaving a foreign package untouched in a mixed batch" do
      other_user = create(:user)
      other_store = create(:shopify_store, user: other_user, company: other_user.companies.first)
      other_customer = create(:customer, shopify_store: other_store)
      foreign = create(:package, shopify_store: other_store, aasm_state: "pending_review", number: 92,
                       order: create(:order, customer: other_customer, shopify_store: other_store))

      post submit_review_bulk_packages_path, params: { package_ids: [ review_package.id, foreign.id ] }

      expect(review_package.reload.aasm_state).to eq("pending_process")
      expect(foreign.reload.aasm_state).to eq("pending_review")
      # The foreign id is silently filtered out by scoped_packages' company
      # scope (same as apply_tracking_bulk/ship_bulk) — it never reaches the
      # find_each loop, so it is NOT counted as skipped.
      expect(flash[:notice]).to eq(I18n.t("packages.review.bulk_result", reviewed: 1, skipped: 0))
    end

    it "does not raise on a malformed non-UUID id and still advances the legitimate package" do
      expect {
        post submit_review_bulk_packages_path, params: { package_ids: [ review_package.id, "not-a-uuid" ] }
      }.not_to raise_error

      expect(response).to redirect_to(packages_path(state: "pending_review"))
      expect(review_package.reload.aasm_state).to eq("pending_process")
      # Same reasoning as the mixed-company case: Rails' UUID cast turns the
      # malformed id into IS NULL in the WHERE clause, so it never matches a
      # row and is not counted as skipped.
      expect(flash[:notice]).to eq(I18n.t("packages.review.bulk_result", reviewed: 1, skipped: 0))
    end

    it "carries the current filters back to the list" do
      post submit_review_bulk_packages_path,
           params: { package_ids: [ review_package.id ], country: "US",
                     sort_column: "paid_at", sort_direction: "asc" }

      expect(response).to redirect_to(
        packages_path(country: "US", sort_column: "paid_at", sort_direction: "asc", state: "pending_review")
      )
    end
  end
end
