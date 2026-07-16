require "rails_helper"

RSpec.describe "Parcels", type: :request do
  let(:user)    { create(:user) }
  let(:company) { user.companies.first }
  let(:store)   { create(:shopify_store, user: user, company: company, cost_fx_rate: 7.2) }
  let(:customer) { create(:customer, shopify_store: store) }

  let!(:cheap) do
    o = create(:order, customer: customer, shopify_store: store, name: "PKS#3001",
                       estimated_shipping_cost: 10, ordered_at: 2.days.ago)
    create(:parcel, shopify_store: store, order: o, identifier: "A1", cost_amount: 11)
    o
  end

  let!(:blown) do
    o = create(:order, customer: customer, shopify_store: store, name: "PKS#3052",
                       estimated_shipping_cost: 18.20, ordered_at: 1.day.ago)
    create(:parcel, shopify_store: store, order: o, identifier: "B1", cost_amount: 20)
    create(:parcel, shopify_store: store, order: o, identifier: "B2", cost_amount: 20.10)
    o
  end

  before { sign_in user }

  describe "GET /parcels" do
    it "lists orders with their estimated, actual and variance" do
      get parcels_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("PKS#3052")
      expect(response.body).to include("PKS#3001")
    end

    it "sorts by variance descending by default (worst overrun first)" do
      get parcels_path
      expect(response.body.index("PKS#3052")).to be < response.body.index("PKS#3001")
    end

    describe "sorting by variance %" do
      # Small absolute overrun (+10) but a HIGH percentage (100%).
      let!(:high_pct) do
        o = create(:order, customer: customer, shopify_store: store, name: "PKS#HIPCT",
                           estimated_shipping_cost: 10, ordered_at: 1.day.ago)
        create(:parcel, shopify_store: store, order: o, identifier: "HP1", cost_amount: 20)
        o
      end

      # Large absolute overrun (+100) but a LOW percentage (10%). This is the
      # pair that distinguishes a percentage sort from the absolute-variance
      # sort: by absolute variance low_pct wins, by percentage high_pct wins.
      let!(:low_pct) do
        o = create(:order, customer: customer, shopify_store: store, name: "PKS#LOPCT",
                           estimated_shipping_cost: 1000, ordered_at: 1.day.ago)
        create(:parcel, shopify_store: store, order: o, identifier: "LP1", cost_amount: 1100)
        o
      end

      it "orders the higher-percentage overrun first on desc, even when its absolute variance is smaller" do
        get parcels_path, params: { sort_column: "variance_pct", sort_direction: "desc" }
        expect(response.body.index("PKS#HIPCT")).to be < response.body.index("PKS#LOPCT")
      end

      it "reverses the order on asc" do
        get parcels_path, params: { sort_column: "variance_pct", sort_direction: "asc" }
        expect(response.body.index("PKS#LOPCT")).to be < response.body.index("PKS#HIPCT")
      end
    end

    it "shows the destination country flag next to the order number on the order row" do
      # No rate card for this order, so the comparator resolves no Basis and the
      # expanded "estimate basis" line (the other place a country flag renders)
      # never appears — the 🇦🇺 flag can therefore only come from the order row
      # itself, which is exactly what this pins.
      au = create(:order, customer: customer, shopify_store: store, name: "PKS#AUFLAG",
                          estimated_shipping_cost: 30, ordered_at: 1.day.ago,
                          shopify_data: { "shipping_address" => { "country_code" => "AU", "zip" => "2000" } })
      create(:parcel, shopify_store: store, order: au, identifier: "AUF1", cost_amount: 40)

      get parcels_path

      expect(response.body).to include("PKS#AUFLAG")
      expect(response.body).to include("🇦🇺")
    end

    describe "country filter" do
      let!(:au_order) do
        o = create(:order, customer: customer, shopify_store: store, name: "PKS#AUCTRY",
                           estimated_shipping_cost: 30, ordered_at: 1.day.ago,
                           shopify_data: { "shipping_address" => { "country_code" => "AU", "zip" => "2000" } })
        create(:parcel, shopify_store: store, order: o, identifier: "AUC1", cost_amount: 40)
        o
      end

      let!(:us_order) do
        o = create(:order, customer: customer, shopify_store: store, name: "PKS#USCTRY",
                           estimated_shipping_cost: 30, ordered_at: 1.day.ago,
                           shopify_data: { "shipping_address" => { "country_code" => "US", "zip" => "10001" } })
        create(:parcel, shopify_store: store, order: o, identifier: "USC1", cost_amount: 40)
        o
      end

      it "keeps only orders whose destination country matches" do
        get parcels_path, params: { country: "AU" }
        expect(response.body).to include("PKS#AUCTRY")
        expect(response.body).not_to include("PKS#USCTRY")
      end

      it "resolves the country from billing when the shipping address has none, matching the row's country" do
        billing_only = create(:order, customer: customer, shopify_store: store, name: "PKS#AUBILL",
                              estimated_shipping_cost: 30, ordered_at: 1.day.ago,
                              shopify_data: { "billing_address" => { "country_code" => "AU", "zip" => "3000" } })
        create(:parcel, shopify_store: store, order: billing_only, identifier: "AUB1", cost_amount: 40)

        get parcels_path, params: { country: "AU" }
        expect(response.body).to include("PKS#AUBILL")
        expect(response.body).to include("PKS#AUCTRY")
        expect(response.body).not_to include("PKS#USCTRY")
      end

      it "treats a whitespace-only shipping country_code as blank and resolves to billing, matching the row" do
        # Mirrors Ruby String#present?: "   " is blank, so both the row display
        # and the filter must fall through to the billing country, not resolve
        # to a bogus "   " code.
        ws = create(:order, customer: customer, shopify_store: store, name: "PKS#AUWS",
                    estimated_shipping_cost: 30, ordered_at: 1.day.ago,
                    shopify_data: { "shipping_address" => { "country_code" => "   " },
                                    "billing_address" => { "country_code" => "AU", "zip" => "3000" } })
        create(:parcel, shopify_store: store, order: ws, identifier: "AUWS1", cost_amount: 40)

        get parcels_path, params: { country: "AU" }
        expect(response.body).to include("PKS#AUWS")
      end

      it "offers each destination country present in the window as a filter option" do
        get parcels_path
        expect(response.body).to include('value="AU"')
        expect(response.body).to include('value="US"')
      end
    end

    it "filters to multi-parcel orders only" do
      get parcels_path, params: { multi_parcel_only: "1" }
      expect(response.body).to include("PKS#3052")
      expect(response.body).not_to include("PKS#3001")
    end

    it "filters to overrun orders only" do
      saver = create(:order, customer: customer, shopify_store: store, name: "PKS#3009",
                             estimated_shipping_cost: 50, ordered_at: 1.day.ago)
      create(:parcel, shopify_store: store, order: saver, identifier: "C1", cost_amount: 10)

      get parcels_path, params: { over_only: "1" }
      expect(response.body).not_to include("PKS#3009")
      expect(response.body).to include("PKS#3052")
    end

    describe "min_over_pct filter" do
      it "includes an order exactly at the threshold and excludes one just below it" do
        at_threshold = create(:order, customer: customer, shopify_store: store, name: "PKS#PCT10",
                               estimated_shipping_cost: 100, ordered_at: 1.day.ago)
        create(:parcel, shopify_store: store, order: at_threshold, identifier: "PCT10A", cost_amount: 110)

        below_threshold = create(:order, customer: customer, shopify_store: store, name: "PKS#PCT9",
                                  estimated_shipping_cost: 100, ordered_at: 1.day.ago)
        create(:parcel, shopify_store: store, order: below_threshold, identifier: "PCT9A", cost_amount: 109.99)

        get parcels_path, params: { min_over_pct: "10" }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("PKS#PCT10")
        expect(response.body).not_to include("PKS#PCT9")
      end

      # This is the mutation-test target for parse_pct's zero handling: if
      # "0" were ever treated as blank (no filter), the under-estimate order
      # below would leak into a request that asked for "≥0% overrun".
      it "treats a threshold of exactly 0 as a real filter, not as blank" do
        over = create(:order, customer: customer, shopify_store: store, name: "PKS#PCTZOVER",
                      estimated_shipping_cost: 100, ordered_at: 1.day.ago)
        create(:parcel, shopify_store: store, order: over, identifier: "PCTZOVER1", cost_amount: 105)

        under = create(:order, customer: customer, shopify_store: store, name: "PKS#PCTZUNDER",
                       estimated_shipping_cost: 100, ordered_at: 1.day.ago)
        create(:parcel, shopify_store: store, order: under, identifier: "PCTZUNDER1", cost_amount: 95)

        get parcels_path, params: { min_over_pct: "0" }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("PKS#PCTZOVER")
        expect(response.body).not_to include("PKS#PCTZUNDER")
      end

      # This is the mutation-test target for the divide-by-zero guard: drop
      # the "orders.estimated_shipping_cost > 0" clause from the SQL and
      # either of these orders (a 0 estimate and a NULL estimate, each with a
      # large actual cost) starts wrongly matching >= any positive threshold.
      it "excludes an order with a zero or nil estimated_shipping_cost even with a large actual cost" do
        zero_estimate = create(:order, customer: customer, shopify_store: store, name: "PKS#ZEROEST",
                                estimated_shipping_cost: 0, ordered_at: 1.day.ago)
        create(:parcel, shopify_store: store, order: zero_estimate, identifier: "ZEROEST1", cost_amount: 500)

        nil_estimate = create(:order, customer: customer, shopify_store: store, name: "PKS#NILEST",
                               estimated_shipping_cost: nil, ordered_at: 1.day.ago)
        create(:parcel, shopify_store: store, order: nil_estimate, identifier: "NILEST1", cost_amount: 500)

        get parcels_path, params: { min_over_pct: "1" }

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("PKS#ZEROEST")
        expect(response.body).not_to include("PKS#NILEST")
      end

      it "applies no filter and does not error on a blank, non-numeric, or negative threshold" do
        saver = create(:order, customer: customer, shopify_store: store, name: "PKS#PCTSAVER",
                       estimated_shipping_cost: 100, ordered_at: 1.day.ago)
        create(:parcel, shopify_store: store, order: saver, identifier: "PCTSAVER1", cost_amount: 50)

        [ "", "abc", "-5" ].each do |bad_value|
          get parcels_path, params: { min_over_pct: bad_value }
          expect(response).to have_http_status(:ok)
          expect(response.body).to include("PKS#PCTSAVER")
        end
      end

      it "repopulates the submitted threshold value in the input" do
        get parcels_path, params: { min_over_pct: "12.5" }

        expect(response.body).to include('value="12.5"')
      end

      it "preserves the min_over_pct filter through the rendered page-2 pagination link" do
        30.times do |i|
          o = create(:order, customer: customer, shopify_store: store, name: "PKS#PCTOVER#{i}",
                             estimated_shipping_cost: 10, ordered_at: (3 + (i % 26)).days.ago)
          create(:parcel, shopify_store: store, order: o, identifier: "PCTOVER#{i}", cost_amount: 12 + (i * 0.01))
        end
        saver = create(:order, customer: customer, shopify_store: store, name: "PKS#PCTSAVER2",
                       estimated_shipping_cost: 100, ordered_at: 4.days.ago)
        create(:parcel, shopify_store: store, order: saver, identifier: "PCTSAVER2A", cost_amount: 50)

        get parcels_path, params: { min_over_pct: "5" }
        expect(response.body).not_to include("PKS#PCTSAVER2")

        href = response.body[/href="([^"]*page=2[^"]*)"/, 1]
        expect(href).to be_present
        expect(href).to include("min_over_pct")

        get href.gsub("&amp;", "&")

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("PKS#PCTSAVER2")
      end
    end

    it "shows unmatched parcels on the unmatched tab" do
      create(:parcel, shopify_store: store, order: nil, identifier: "ORPHAN1")

      get parcels_path, params: { tab: "unmatched" }
      expect(response.body).to include("ORPHAN1")
    end

    it "denies a member without the parcels permission" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [])
      sign_out user
      sign_in member

      get parcels_path
      expect(response).to redirect_to(authenticated_root_path)
    end

    it "allows a member who has the parcels permission" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "parcels" ])
      sign_out user
      sign_in member

      get parcels_path
      expect(response).to have_http_status(:ok)
    end

    it "renders a page-2 link and makes page 2 reachable with different orders than page 1" do
      30.times do |i|
        o = create(:order, customer: customer, shopify_store: store, name: "PKS#OVER#{i}",
                           estimated_shipping_cost: 10, ordered_at: (3 + (i % 26)).days.ago)
        create(:parcel, shopify_store: store, order: o, identifier: "OVER#{i}", cost_amount: 12 + (i * 0.01))
      end

      get parcels_path
      expect(response.body).to match(/href="[^"]*page=2[^"]*"/)
      page1_names = response.body.scan(/PKS#OVER\d+/).uniq

      get parcels_path, params: { page: 2 }
      page2_names = response.body.scan(/PKS#OVER\d+/).uniq

      expect(page1_names).not_to be_empty
      expect(page2_names).not_to be_empty
      expect(page1_names & page2_names).to be_empty
    end

    # The controller has always accepted a `page` param — that alone proves
    # nothing about the view. This test only passes if the rendered page-2
    # link (a) exists and (b) still carries over_only=1, since the "saver"
    # order is constructed to sort dead last and would only surface on the
    # followed link if the filter were dropped.
    it "preserves the over_only filter through the rendered page-2 pagination link" do
      30.times do |i|
        o = create(:order, customer: customer, shopify_store: store, name: "PKS#OVER#{i}",
                           estimated_shipping_cost: 10, ordered_at: (3 + (i % 26)).days.ago)
        create(:parcel, shopify_store: store, order: o, identifier: "OVER#{i}", cost_amount: 12 + (i * 0.01))
      end
      saver = create(:order, customer: customer, shopify_store: store, name: "PKS#SAVER",
                             estimated_shipping_cost: 100, ordered_at: 4.days.ago)
      create(:parcel, shopify_store: store, order: saver, identifier: "SAVER1", cost_amount: 10)

      get parcels_path, params: { over_only: "1" }
      expect(response.body).not_to include("PKS#SAVER")

      href = response.body[/href="([^"]*page=2[^"]*)"/, 1]
      expect(href).to be_present

      get href.gsub("&amp;", "&")

      expect(response.body).not_to include("PKS#SAVER")
    end

    # A named order beyond the old .limit(200) simply wasn't in the assign
    # dropdown, with no error — an operator could never assign an unmatched
    # parcel to it. With 434 orders in a real month's bill this was a real,
    # not theoretical, ceiling.
    it "offers an order beyond the old 200-row cap in the unmatched-tab assign dropdown" do
      create(:parcel, shopify_store: store, order: nil, identifier: "CAPTEST")
      oldest_order = nil
      205.times do |i|
        o = create(:order, customer: customer, shopify_store: store, name: "PKS#CAP#{i}", ordered_at: (i + 1).days.ago)
        oldest_order = o if i == 204
      end

      get parcels_path, params: { tab: "unmatched" }

      expect(response.body).to include(oldest_order.name)
    end

    # The dropdown must stay complete (see the test above) without
    # re-rendering the full option list into every unmatched row's markup —
    # that scaled page weight as rows × orders (measured 127 KB for 300
    # orders × 5 unmatched rows; a real month's 434 orders/25-row page would
    # run into multiple MB). The full order list should be rendered once
    # (into the shared <template>), not once per row.
    it "renders the assignable-orders option list once, not once per unmatched row" do
      40.times do |i|
        create(:order, customer: customer, shopify_store: store, name: "PKS#OPT#{i}", ordered_at: (i + 1).days.ago)
      end
      row_count = 6
      row_count.times { |i| create(:parcel, shopify_store: store, order: nil, identifier: "OPTROW#{i}") }

      get parcels_path, params: { tab: "unmatched" }

      named_order_count = Order.where(shopify_store: store).where.not(name: nil).count
      option_count = response.body.scan(/<option\b/).size

      # Reverting to per-row `options_from_collection_for_select` would emit
      # (named_order_count + 1 blank) options for EVERY row on the page —
      # here row_count * (named_order_count + 1). Rendering the list once
      # (plus one blank placeholder <option> per row's otherwise-empty
      # <select>) keeps option_count flat regardless of row_count.
      expect(option_count).to be < (named_order_count + row_count + 5)
      expect(option_count).to be < (row_count * named_order_count)
    end

    it "renders a page-2 link and makes page 2 reachable on the unmatched tab with more than 25 unmatched parcels" do
      30.times { |i| create(:parcel, shopify_store: store, order: nil, identifier: "ORPHAN#{i}", shipped_at: (i + 1).hours.ago) }

      get parcels_path, params: { tab: "unmatched" }
      expect(response.body).to match(/href="[^"]*page=2[^"]*"/)
      page1_ids = response.body.scan(/ORPHAN\d+/).uniq

      get parcels_path, params: { tab: "unmatched", page: 2 }
      page2_ids = response.body.scan(/ORPHAN\d+/).uniq

      expect(page1_ids).not_to be_empty
      expect(page2_ids).not_to be_empty
      expect(page1_ids & page2_ids).to be_empty
    end
  end

  describe "PATCH /parcels/:id" do
    it "updates the cost and re-rolls up the order" do
      parcel = blown.parcels.find_by(identifier: "B1")

      patch parcel_path(id: parcel.id), params: { parcel: { cost_cny: "72.00" } }

      expect(parcel.reload.cost_cny).to eq(72)
      expect(parcel.cost_amount).to eq(10)             # 72 / 7.2, recomputed on write
      expect(blown.reload.actual_shipping_cost).to eq(30.10)
    end

    it "assigns an unmatched parcel to an order and rolls up" do
      orphan = create(:parcel, shopify_store: store, order: nil, identifier: "ORPHAN1", cost_amount: 5)

      patch parcel_path(id: orphan.id), params: { parcel: { order_id: cheap.id } }

      expect(orphan.reload.order_id).to eq(cheap.id)
      expect(cheap.reload.actual_shipping_cost).to eq(16)   # 11 + 5
    end

    # Cross-company scoping: recomputed_attrs must re-look-up the order_id
    # through visible_shopify_stores. Without that re-lookup, a user could
    # attach a parcel to any order id they can guess, including one that
    # belongs to a completely different company.
    it "refuses to assign a parcel to another company's order" do
      other_user = create(:user)
      other_company = other_user.companies.first
      other_store = create(:shopify_store, user: other_user, company: other_company, cost_fx_rate: 6)
      other_customer = create(:customer, shopify_store: other_store)
      other_order = create(:order, customer: other_customer, shopify_store: other_store, name: "OTHER#1")

      orphan = create(:parcel, shopify_store: store, order: nil, identifier: "ORPHAN2", cost_amount: 5)

      patch parcel_path(id: orphan.id), params: { parcel: { order_id: other_order.id } }

      expect(orphan.reload.order_id).to be_nil
      expect(other_order.reload.actual_shipping_cost).to be_nil
    end

    # The two tabs render a parcel with different markup (unmatched: 5 columns
    # + assign form; orders: 8 columns + cost field), so the turbo_stream reply
    # has to match the tab the edit came from. Streaming _parcel_row into the
    # unmatched table would corrupt it.
    describe "turbo_stream response" do
      let(:turbo) { { "ACCEPT" => "text/vnd.turbo-stream.html" } }

      it "replaces the row with the orders-tab markup on a cost edit" do
        parcel = blown.parcels.find_by(identifier: "B1")

        patch parcel_path(id: parcel.id), params: { parcel: { cost_cny: "72.00" } }, headers: turbo

        expect(response.media_type).to eq("text/vnd.turbo-stream.html")
        expect(response.body).to include(%(action="replace"))
        expect(response.body).to include(%(target="#{ActionView::RecordIdentifier.dom_id(parcel)}"))
        expect(response.body).to include("$10.00")   # recomputed cost_amount, 72 / 7.2
      end

      # A parcel that just got assigned is no longer unmatched, so its row must
      # leave that tab. Replacing it there would leave a stale, now-wrong row.
      it "removes the row when an unmatched parcel is assigned from the unmatched tab" do
        orphan = create(:parcel, shopify_store: store, order: nil, identifier: "ORPHAN3", cost_amount: 5)

        patch parcel_path(id: orphan.id),
              params: { tab: "unmatched", parcel: { order_id: cheap.id } }, headers: turbo

        expect(response.body).to include(%(action="remove"))
        expect(response.body).to include(%(target="#{ActionView::RecordIdentifier.dom_id(orphan)}"))
        expect(orphan.reload.order_id).to eq(cheap.id)
      end

      # Blank order_id: the parcel stays unmatched, so it stays on the tab and
      # must be re-rendered with the unmatched markup, not the orders markup.
      it "re-renders the unmatched row when the assignment is left blank" do
        orphan = create(:parcel, shopify_store: store, order: nil, identifier: "ORPHAN4", cost_amount: 5)

        patch parcel_path(id: orphan.id),
              params: { tab: "unmatched", parcel: { order_id: "" } }, headers: turbo

        expect(response.body).to include(%(action="replace"))
        expect(response.body).to include(I18n.t("parcels.assign"))
        expect(response.body).not_to include(I18n.t("parcels.save"))
        expect(orphan.reload.order_id).to be_nil
      end
    end

    it "rejects a non-owner member" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "parcels" ])
      sign_out user
      sign_in member

      patch parcel_path(id: blown.parcels.first.id), params: { parcel: { cost_cny: "1" } }
      expect(response).to redirect_to(authenticated_root_path)
    end

    # cost_amount is NOT NULL: a parcel without a cost cannot exist. Clearing
    # the ¥ field used to leave cost_cny blank while silently keeping the OLD
    # cost_amount (and the order's rollup) — the operator would see a blank
    # cell and think they'd zeroed out a bogus cost, when the stale money was
    # actually still there. Rejecting the blank makes that impossible: the
    # operator has to delete the parcel instead.
    it "rejects clearing cost_cny instead of silently keeping the stale cost_amount" do
      parcel = blown.parcels.find_by(identifier: "B1")

      patch parcel_path(id: parcel.id), params: { parcel: { cost_cny: "" } }

      expect(response).to redirect_to(parcels_path)
      expect(flash[:alert]).to be_present
      expect(parcel.reload.cost_cny).to eq(239.73)  # unchanged — factory default
      expect(parcel.cost_amount).to eq(20)          # unchanged — the stale value stays stale, but isn't hidden
      expect(blown.reload.actual_shipping_cost).to eq(40.10)
    end

    # BigDecimal("abc") raises ArgumentError; the controller must not let that
    # escape as a 500 — a non-numeric paste needs to land in the same
    # alert-and-redirect path as any other invalid edit.
    it "does not 500 on a non-numeric cost_cny" do
      parcel = blown.parcels.find_by(identifier: "B1")

      patch parcel_path(id: parcel.id), params: { parcel: { cost_cny: "not-a-number" } }

      expect(response).to redirect_to(parcels_path)
      expect(flash[:alert]).to be_present
      expect(parcel.reload.cost_cny).to eq(239.73)  # unchanged — factory default
      expect(parcel.cost_amount).to eq(20)          # unchanged
    end

    # confirm_import and the agent API both rescue ActiveRecord::RangeError,
    # but the HTML inline edit didn't — a value past decimal(10,2)'s range
    # reached the database and raised, 500ing instead of landing in the same
    # alert-and-redirect path as any other invalid edit. The fix bounds
    # cost_cny/cost_amount in the model (Parcel::MAX_DECIMAL), so this now
    # fails ordinary validation before ever reaching the database.
    it "does not 500 on an out-of-range cost_cny via the HTML inline edit" do
      parcel = blown.parcels.find_by(identifier: "B1")

      patch parcel_path(id: parcel.id), params: { parcel: { cost_cny: "999999999999" } }

      expect(response).to redirect_to(parcels_path)
      expect(flash[:alert]).to be_present
      expect(parcel.reload.cost_cny).to eq(239.73)  # unchanged — factory default
      expect(parcel.cost_amount).to eq(20)          # unchanged
    end

    # The upper bound must not accidentally reject the largest legal value —
    # decimal(10,2)'s true maximum is 99999999.99.
    it "still accepts the decimal(10,2) column's true maximum cost_cny" do
      parcel = blown.parcels.find_by(identifier: "B1")

      patch parcel_path(id: parcel.id), params: { parcel: { cost_cny: "99999999.99" } }

      expect(response).to redirect_to(parcels_path)
      expect(flash[:alert]).to be_nil
      expect(parcel.reload.cost_cny).to eq(BigDecimal("99999999.99"))
    end
  end

  describe "DELETE /parcels/:id" do
    it "destroys the parcel and re-rolls up" do
      parcel = cheap.parcels.first

      delete parcel_path(id: parcel.id)

      expect(cheap.reload.actual_shipping_cost).to be_nil
    end

    it "rejects a non-owner member" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "parcels" ])
      sign_out user
      sign_in member

      parcel = cheap.parcels.first

      expect {
        delete parcel_path(id: parcel.id)
      }.not_to change(Parcel, :count)
      expect(response).to redirect_to(authenticated_root_path)
    end
  end

  # Per-parcel estimate comparison (Task 2 of the estimate-comparison-and-export
  # feature): rate card + postal-zone fixtures shared by every example below.
  describe "GET /parcels — per-parcel estimate comparison (orders tab)" do
    let(:est_store) do
      create(:shopify_store, user: user, company: company, currency: "USD",
             cost_fx_rate: 7.0, default_service_type: "with_battery")
    end
    let(:est_customer) { create(:customer, shopify_store: est_store) }

    before do
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "1", postal_start: "2000", postal_end: "2079")
      create(:shipping_zone_postal_rule, company: company, country_code: "AU", zone: "2", postal_start: "2080", postal_end: "2084")
      version = create(:shipping_rate_card_version, company: company, country_code: "AU",
                        service_type: "with_battery", effective_from: Date.new(2020, 1, 1))
      create(:shipping_rate_card_rate, version: version, zone: "1", weight_min_kg: 0, weight_max_kg: 5, per_kg_rate_cny: 30, flat_fee_cny: 25)
      create(:shipping_rate_card_rate, version: version, zone: "2", weight_min_kg: 0, weight_max_kg: 5, per_kg_rate_cny: 40, flat_fee_cny: 35)
    end

    # An order the comparator can price: AU, zoned postal code, one line item
    # with a real weight so ShippingCostCalculator::Basis resolves.
    def priced_order(name:, zip:, weight_grams:)
      o = create(:order, customer: est_customer, shopify_store: est_store, name: name,
                 ordered_at: 1.day.ago,
                 shopify_data: { "shipping_address" => { "country_code" => "AU", "zip" => zip } })
      product = create(:product, shopify_store: est_store)
      variant = create(:product_variant, product: product, weight_grams: weight_grams)
      create(:order_line_item, order: o, product_variant: variant, quantity: 1)
      o
    end

    # This is the mutation-test target for the zone-mismatch badge condition:
    # the badge markup only ever renders from two places (the order-row badge
    # and the per-parcel zone2 cell's inline warning), both gated on
    # `zone_mismatch`/`any_zone_mismatch`. Asserting the exact total count
    # across the whole page — not just "is present somewhere" — fails both if
    # the gate is dropped (badge leaks onto the zone-matching order too, count
    # goes to 4) and if it's hardcoded off (count goes to 0).
    it "renders the zone-mismatch badge and a red zone cell only for the order whose billed zone differs from its estimated zone" do
      mismatched = priced_order(name: "PKS#ZMIS", zip: "2075", weight_grams: 1250) # estimated zone "1"
      create(:parcel, shopify_store: est_store, order: mismatched, identifier: "ZM1", zone: "2",
             billed_weight_g: 1250, cost_cny: 106.25, fx_rate_snapshot: 7.0, cost_amount: 15.18)

      matched = priced_order(name: "PKS#ZOK", zip: "2075", weight_grams: 1250) # estimated zone "1"
      create(:parcel, shopify_store: est_store, order: matched, identifier: "ZOK1", zone: "1",
             billed_weight_g: 1250, cost_cny: 62.50, fx_rate_snapshot: 7.0, cost_amount: 8.93)

      get parcels_path

      expect(response).to have_http_status(:ok)
      badge = I18n.t("parcels.zone_mismatch_badge")
      expect(response.body.scan(badge).size).to eq(2) # order-row badge + per-parcel zone2 badge, mismatched order only
      expect(response.body).to include("text-red-600")
    end

    # Per-parcel estimate/actual/variance, each in CNY (primary) and USD
    # (secondary) — the report's core new data, not present on the report at
    # all before this feature.
    it "renders per-parcel estimate, actual and variance in both CNY and USD" do
      order = priced_order(name: "PKS#PLINE", zip: "2075", weight_grams: 1500) # billed weight matches order weight: no split
      create(:parcel, shopify_store: est_store, order: order, identifier: "PLINE1", zone: "1",
             billed_weight_g: 1500, cost_cny: 80, fx_rate_snapshot: 7.2, cost_amount: 11.11)

      get parcels_path

      # estimate: 1.5kg * 30 + 25 = 70 CNY -> 70 / 7.0 = 10.00 USD
      expect(response.body).to include("¥70.00")
      expect(response.body).to include("$10.00")
      # actual: straight from the parcel's own billed/converted figures
      expect(response.body).to include("¥80.00")
      expect(response.body).to include("$11.11")
      # variance: 80 - 70 = 10 CNY; USD variance is actual($11.11) - estimate($10.00) = +$1.11
      # (NOT cny-variance/fx_rate — actual/estimate each convert independently,
      # via the parcel's own stored cost_amount and the basis fx_rate respectively).
      # pct = variance_cny / estimate_cny * 100 = 10/70*100 = 14.29%
      expect(response.body).to include("+¥10.00")
      expect(response.body).to include("+$1.11")
      expect(response.body).to include("+14.29%")
    end

    # The two-term decomposition (折包代價 + 物流商可能超收) only ever renders
    # when EVERY parcel on the order has a usable estimate — this is the
    # money-correctness guard from ParcelEstimateComparator#decomposable, and
    # the view must respect it (hide the section, not show a partially-wrong
    # split) rather than re-deriving its own looser condition.
    it "renders the split-cost/overcharge decomposition for a decomposable order and a fallback message when one parcel is missing billed weight" do
      decomposable = priced_order(name: "PKS#DECOMP", zip: "2075", weight_grams: 2500) # order estimate 100 CNY
      create(:parcel, shopify_store: est_store, order: decomposable, identifier: "D1", zone: "1",
             billed_weight_g: 1500, cost_cny: 80, fx_rate_snapshot: 7.0, cost_amount: 11.43)
      create(:parcel, shopify_store: est_store, order: decomposable, identifier: "D2", zone: "1",
             billed_weight_g: 1000, cost_cny: 50, fx_rate_snapshot: 7.0, cost_amount: 7.14)

      incomplete = priced_order(name: "PKS#NODECOMP", zip: "2075", weight_grams: 2500)
      create(:parcel, shopify_store: est_store, order: incomplete, identifier: "N1", zone: "1",
             billed_weight_g: 1000, cost_cny: 55, fx_rate_snapshot: 7.0, cost_amount: 7.86)
      create(:parcel, shopify_store: est_store, order: incomplete, identifier: "N2", zone: "1",
             billed_weight_g: nil, cost_cny: 50, fx_rate_snapshot: 7.0, cost_amount: 7.14)

      get parcels_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("parcels.recon.split_label"))
      expect(response.body).to include(I18n.t("parcels.recon.overcharge_label"))
      expect(response.body).to include(I18n.t("parcels.recon.unavailable"))
    end

    # Fix-brief item 1: the recon block's three USD figures (total / split /
    # overcharge) must all derive from the same basis (CNY ÷ basis.fx_rate)
    # so "total == split + overcharge" holds on screen, exactly like the CNY
    # figures already do. Before the fix, the "total" USD used the order-row
    # rollup (order.actual_shipping_cost - order_estimate) instead, which is
    # free to drift from split_usd + overcharge_usd whenever a parcel's own
    # cost_amount wasn't converted at the same fx rate as the basis — as it
    # deliberately isn't here, to force that drift.
    it "renders a recon total USD that equals split USD + overcharge USD, even when the order-row rollup would disagree" do
      order = priced_order(name: "PKS#RECONUSD", zip: "2075", weight_grams: 2500) # order estimate 100 CNY
      # D1/D2 estimates: 70 + 55 = 125 CNY -> split_cost_cny = 125 - 100 = 25
      # actual: 80 + 50 = 130 CNY -> overcharge_cny = 130 - 125 = 5
      # basis.fx_rate is 7.0 (est_store.cost_fx_rate), so:
      #   split_usd      = (25 / 7.0).round(2) = 3.57
      #   overcharge_usd = (5  / 7.0).round(2) = 0.71
      #   recon total    = 3.57 + 0.71         = 4.28
      # cost_amount below is set independently of cost_cny / basis.fx_rate
      # (as a real parcel's own fx_rate_snapshot conversion would be), so the
      # order-row rollup (actual_shipping_cost 17.81 - order_estimate 14.29
      # = 3.52) intentionally disagrees with 4.28 — proving the recon block
      # no longer reads that rollup for its "total" line.
      create(:parcel, shopify_store: est_store, order: order, identifier: "RU1", zone: "1",
             billed_weight_g: 1500, cost_cny: 80, fx_rate_snapshot: 7.5, cost_amount: 10.67)
      create(:parcel, shopify_store: est_store, order: order, identifier: "RU2", zone: "1",
             billed_weight_g: 1000, cost_cny: 50, fx_rate_snapshot: 7.0, cost_amount: 7.14)

      get parcels_path

      expect(response).to have_http_status(:ok)
      # Note: the order-row widget legitimately shows the rollup figure
      # (+$3.52) elsewhere on the page — that's the OTHER widget the fix
      # brief says must stay untouched. So these assertions are scoped to
      # just the recon block (".bg-purple-50"), not the whole response body,
      # to actually pin down which figure the recon section itself renders.
      recon = Nokogiri::HTML(response.body).at_css(".bg-purple-50").text
      expect(recon).to include("+$3.57") # split USD
      expect(recon).to include("+$0.71") # overcharge USD
      expect(recon).to include("+$4.28") # recon total USD == 3.57 + 0.71
      expect(recon).not_to include("+$3.52") # the stale order-row-rollup figure must not leak in here
    end

    # N+1 guard: Step 1's review flagged that ShippingCostCalculator.basis
    # does a ShippingRateCardVersion lookup (+ postal-zone resolution) PER
    # ORDER. Without ParcelsController#index sharing one cache across all
    # orders on the page (@estimate_cache), a 25-order page does 25 separate
    # rate-card-version lookups. Every order here shares the exact same
    # (company, country, service_type, date) key, so a working cache collapses
    # them to a small constant; a broken one scales 1:1 with order count.
    it "looks up the rate card version and the postal zone a small constant number of times, not once per order on the page" do
      10.times do |i|
        order = priced_order(name: "PKS#NPLUS1#{i}", zip: "2075", weight_grams: 1000 + i)
        create(:parcel, shopify_store: est_store, order: order, identifier: "NPLUS1#{i}",
               zone: "1", billed_weight_g: 1000 + i, cost_cny: 50 + i, fx_rate_snapshot: 7.0, cost_amount: (50 + i) / 7.0)
      end

      version_lookup_count = 0
      # Companion N+1 guard to the rate-card-version one below: basis
      # resolution also does a ShippingZonePostalRule.zone_for lookup per
      # order (see ShippingCostCalculator#fetch_zone_for's cache_slot(:zone_for)
      # cache). All 10 orders here share the same (company, country, key)
      # cache key, so a working per-request cache collapses this to a small
      # constant too — a broken/dropped cache scales 1:1 with order count.
      postal_zone_lookup_count = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        version_lookup_count += 1 if payload[:sql]&.include?("shipping_rate_card_versions")
        postal_zone_lookup_count += 1 if payload[:sql]&.include?("shipping_zone_postal_rules")
      end

      begin
        get parcels_path
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(response).to have_http_status(:ok)
      # 10 orders, all the same (company, country, service_type, date) key —
      # a shared per-request cache does this lookup once (or a small constant
      # number of times), never anywhere close to once per order.
      expect(version_lookup_count).to be > 0
      expect(version_lookup_count).to be < 5
      # Same story for the postal-zone lookup: constant, not one-per-order.
      expect(postal_zone_lookup_count).to be > 0
      expect(postal_zone_lookup_count).to be < 5
    end
  end
end
