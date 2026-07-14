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
end
