require "rails_helper"

RSpec.describe "Shipments", type: :request do
  let(:user) { create(:user) }
  let(:store) { create(:shopify_store, user: user) }
  let(:customer) { create(:customer, shopify_store: store) }

  before { sign_in user }

  describe "GET /shipments" do
    it "renders the index page" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "TRACK1", tracking_status: "InTransit")

      get shipments_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("TRACK1")
    end

    it "shows status tab counts" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "T1", tracking_status: "InTransit")
      create(:fulfillment, order: order, tracking_number: "T2", tracking_status: "Delivered")
      create(:fulfillment, order: order, tracking_number: "T3", tracking_status: "Delivered")

      get shipments_path
      expect(response.body).to include("All (3)")
      expect(response.body).to include("In Transit (1)")
      expect(response.body).to include("Delivered (2)")
    end

    it "shows shipments across multiple stores when no store selected" do
      store2 = create(:shopify_store, user: user)
      customer2 = create(:customer, shopify_store: store2)
      order1 = create(:order, customer: customer, shopify_store: store)
      order2 = create(:order, customer: customer2, shopify_store: store2)
      create(:fulfillment, order: order1, tracking_number: "STORE1-T", tracking_status: "InTransit")
      create(:fulfillment, order: order2, tracking_number: "STORE2-T", tracking_status: "InTransit")

      get shipments_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("STORE1-T")
      expect(response.body).to include("STORE2-T")
    end

    it "filters by status tab" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "T1", tracking_status: "InTransit")
      create(:fulfillment, order: order, tracking_number: "T2", tracking_status: "Delivered")

      get shipments_path, params: { status_tab: "InTransit" }
      expect(response.body).to include("T1")
      expect(response.body).not_to include("T2")
    end

    it "filters by search query on tracking number" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "DOR019055CN", tracking_status: "InTransit")
      create(:fulfillment, order: order, tracking_number: "OTHER123", tracking_status: "InTransit")

      get shipments_path, params: { search: "DOR019" }
      expect(response.body).to include("DOR019055CN")
      expect(response.body).not_to include("OTHER123")
    end

    it "filters by destination country" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "DEST_MATCH_US99", tracking_status: "InTransit", destination_country: "US")
      create(:fulfillment, order: order, tracking_number: "DEST_EXCLUDED_AU77", tracking_status: "InTransit", destination_country: "AU")

      get shipments_path, params: { destination: "US" }
      expect(response.body).to include("DEST_MATCH_US99")
      expect(response.body).not_to include("DEST_EXCLUDED_AU77")
    end

    it "filters by origin carrier" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "CARRIER_CHINA_POST88", tracking_status: "InTransit", origin_carrier: "China Post")
      create(:fulfillment, order: order, tracking_number: "CARRIER_DHL_EXCLUDED55", tracking_status: "InTransit", origin_carrier: "DHL")

      get shipments_path, params: { origin_carrier: "China Post" }
      expect(response.body).to include("CARRIER_CHINA_POST88")
      expect(response.body).not_to include("CARRIER_DHL_EXCLUDED55")
    end

    it "sorts by sort_field and sort_direction" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "OLD", tracking_status: "InTransit", created_at: 2.days.ago)
      create(:fulfillment, order: order, tracking_number: "NEW", tracking_status: "InTransit", created_at: 1.hour.ago)

      get shipments_path, params: { sort_field: "input_time", sort_direction: "asc" }
      expect(response.body.index("OLD")).to be < response.body.index("NEW")
    end

    it "paginates results" do
      order = create(:order, customer: customer, shopify_store: store)
      30.times { |i| create(:fulfillment, order: order, tracking_number: "TRACK#{i}", tracking_status: "InTransit") }

      get shipments_path, params: { page: 1 }
      expect(response.body).to include("Showing 1-25 of 30")
    end

    it "respects per_page parameter with allowed value" do
      order = create(:order, customer: customer, shopify_store: store)
      60.times { |i| create(:fulfillment, order: order, tracking_number: "PP#{i.to_s.rjust(3, '0')}", tracking_status: "InTransit") }

      get shipments_path, params: { per_page: 50 }
      expect(response.body).to include("Showing 1-50 of 60")
    end

    it "falls back to default per_page for invalid values" do
      order = create(:order, customer: customer, shopify_store: store)
      30.times { |i| create(:fulfillment, order: order, tracking_number: "FB#{i.to_s.rjust(3, '0')}", tracking_status: "InTransit") }

      get shipments_path, params: { per_page: 999 }
      expect(response.body).to include("Showing 1-25 of 30")
    end

    it "filters by destination carrier" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "TRACK-USPS-001", tracking_status: "InTransit", destination_carrier: "USPS")
      create(:fulfillment, order: order, tracking_number: "TRACK-FEDEX-001", tracking_status: "InTransit", destination_carrier: "FedEx")

      get shipments_path, params: { destination_carrier: "USPS" }
      expect(response.body).to include("TRACK-USPS-001")
      expect(response.body).not_to include("TRACK-FEDEX-001")
    end

    it "filters by latest event update time range" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "OLD", tracking_status: "InTransit", last_event_at: 10.days.ago)
      create(:fulfillment, order: order, tracking_number: "RECENT", tracking_status: "InTransit", last_event_at: 1.day.ago)

      get shipments_path, params: { event_from: 3.days.ago.to_date.to_s }
      expect(response.body).to include("RECENT")
      expect(response.body).not_to include("OLD")
    end

    it "filters by latest event update time range with end date" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "OLD", tracking_status: "InTransit", last_event_at: 10.days.ago)
      create(:fulfillment, order: order, tracking_number: "RECENT", tracking_status: "InTransit", last_event_at: 1.day.ago)

      get shipments_path, params: { event_to: 5.days.ago.to_date.to_s }
      expect(response.body).to include("OLD")
      expect(response.body).not_to include("RECENT")
    end

    it "filters by transit time min days" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "FAST", tracking_status: "Delivered", transit_days: 3)
      create(:fulfillment, order: order, tracking_number: "SLOW", tracking_status: "Delivered", transit_days: 15)

      get shipments_path, params: { transit_min: "10" }
      expect(response.body).to include("SLOW")
      expect(response.body).not_to include("FAST")
    end

    it "filters by transit time max days" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "FAST", tracking_status: "Delivered", transit_days: 3)
      create(:fulfillment, order: order, tracking_number: "SLOW", tracking_status: "Delivered", transit_days: 15)

      get shipments_path, params: { transit_max: "5" }
      expect(response.body).to include("FAST")
      expect(response.body).not_to include("SLOW")
    end

    it "filters by sub_status" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "T1", tracking_status: "InTransit", tracking_sub_status: "InTransit_Collected")
      create(:fulfillment, order: order, tracking_number: "T2", tracking_status: "InTransit", tracking_sub_status: "InTransit_CustomsProcessing")

      get shipments_path, params: { sub_status: "InTransit_Collected" }
      expect(response.body).to include("T1")
      expect(response.body).not_to include("T2")
    end

    it "filters by status dropdown" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "EXCEPTION001", tracking_status: "Exception")
      create(:fulfillment, order: order, tracking_number: "INTRANSIT001", tracking_status: "InTransit")

      get shipments_path, params: { status: "Exception" }
      expect(response.body).to include("EXCEPTION001")
      expect(response.body).not_to include("INTRANSIT001")
    end

    it "filters by store_id when user has multiple stores" do
      store2 = create(:shopify_store, user: user)
      customer2 = create(:customer, shopify_store: store2)
      order1 = create(:order, customer: customer, shopify_store: store)
      order2 = create(:order, customer: customer2, shopify_store: store2)
      create(:fulfillment, order: order1, tracking_number: "STORE1", tracking_status: "InTransit")
      create(:fulfillment, order: order2, tracking_number: "STORE2", tracking_status: "InTransit")

      get shipments_path, params: { store_id: store.id }
      expect(response.body).to include("STORE1")
      expect(response.body).not_to include("STORE2")
    end

    it "scopes to single store when current_shopify_store is set" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "SCOPED", tracking_status: "InTransit")

      get shipments_path, params: { store_id: store.id }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("SCOPED")
    end

    it "shows empty state when no shipments" do
      store # ensure store exists
      get shipments_path
      expect(response.body).to include("No shipments found")
    end

    it "filters by single tag" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "TAGGED", tracking_status: "InTransit", tags: %w[vip urgent])
      create(:fulfillment, order: order, tracking_number: "NOTAG", tracking_status: "InTransit", tags: [])

      get shipments_path, params: { tags: [ "vip" ] }
      expect(response.body).to include("TAGGED")
      expect(response.body).not_to include("NOTAG")
    end

    it "filters by multiple tags with OR logic" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "HAS_VIP", tracking_status: "InTransit", tags: %w[vip])
      create(:fulfillment, order: order, tracking_number: "HAS_URGENT", tracking_status: "InTransit", tags: %w[urgent])
      create(:fulfillment, order: order, tracking_number: "HAS_NONE", tracking_status: "InTransit", tags: %w[other])

      get shipments_path, params: { tags: %w[vip urgent] }
      expect(response.body).to include("HAS_VIP")
      expect(response.body).to include("HAS_URGENT")
      expect(response.body).not_to include("HAS_NONE")
    end

    it "only shows shipments for current user stores" do
      other_user = create(:user)
      other_store = create(:shopify_store, user: other_user)
      other_customer = create(:customer, shopify_store: other_store)
      other_order = create(:order, customer: other_customer, shopify_store: other_store)
      create(:fulfillment, order: other_order, tracking_number: "OTHER_STORE", tracking_status: "InTransit")

      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "MY_STORE", tracking_status: "InTransit")

      get shipments_path
      expect(response.body).to include("MY_STORE")
      expect(response.body).not_to include("OTHER_STORE")
    end
  end

  describe "GET /shipments/:id" do
    it "renders the show page with tracking and order data" do
      order = create(:order, customer: customer, shopify_store: store, name: "PKS#9999",
                     shopify_data: {
                       "line_items" => [
                         { "title" => "Widget", "variant_title" => "Red / Large", "sku" => "WDG-001", "price" => "19.99", "quantity" => 2 }
                       ],
                       "shipping_address" => { "name" => "Jane Doe", "phone" => "+1234567890", "address1" => "123 Main St", "city" => "Springfield", "province" => "IL", "zip" => "62704", "country" => "United States" },
                       "shipping_lines" => [
                         { "title" => "Standard Shipping", "price" => "5.99" }
                       ]
                     })
      fulfillment = create(:fulfillment, order: order, tracking_number: "SHOW123", tracking_status: "InTransit",
                           tracking_company: "USPS", origin_country: "CN", destination_country: "US",
                           origin_carrier: "China Post", destination_carrier: "USPS", transit_days: 12,
                           last_event_at: 1.day.ago, latest_event_description: "Arrived at destination port",
                           tracking_details: {
                             "events" => [
                               { "description" => "Arrived at destination port", "time" => "2026-04-02T08:14:00+08:00", "location" => "Los Angeles" },
                               { "description" => "Departed sorting center", "time" => "2026-04-01T05:20:00+08:00", "location" => "Guangzhou" }
                             ]
                           })

      get shipment_path(id: fulfillment.id)
      expect(response).to have_http_status(:ok)

      body = response.body
      # Header
      expect(body).to include("SHOW123")
      expect(body).to include("USPS")
      # Status
      expect(body).to include("In Transit")
      # Timeline events
      expect(body).to include("Arrived at destination port")
      expect(body).to include("Departed sorting center")
      expect(body).to include("Los Angeles")
      # Order info
      expect(body).to include("PKS#9999")
      # Products
      expect(body).to include("Widget")
      expect(body).to include("WDG-001")
      expect(body).to include("Red / Large")
      # Customer / Shipping address
      expect(body).to include("Jane Doe")
      expect(body).to include("123 Main St")
      expect(body).to include("Springfield")
    end

    it "renders gracefully when optional data is missing" do
      order = create(:order, customer: customer, shopify_store: store)
      fulfillment = create(:fulfillment, order: order, tracking_number: "MINIMAL1",
                           tracking_status: "NotFound", tracking_details: {}, shopify_data: {})

      get shipment_path(id: fulfillment.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("MINIMAL1")
      expect(response.body).to include(I18n.t("shipments.show.no_tracking"))
    end

    it "returns 404 for shipments belonging to another company" do
      other_user = create(:user)
      other_store = create(:shopify_store, user: other_user)
      other_customer = create(:customer, shopify_store: other_store)
      other_order = create(:order, customer: other_customer, shopify_store: other_store)
      other_fulfillment = create(:fulfillment, order: other_order, tracking_number: "NOTMINE")

      get shipment_path(id: other_fulfillment.id)
      expect(response).to have_http_status(:not_found)
    end

    it "displays times in UTC+8" do
      order = create(:order, customer: customer, shopify_store: store)
      fulfillment = create(:fulfillment, order: order, tracking_number: "TZTEST",
                           tracking_status: "InTransit",
                           shipped_at: Time.zone.parse("2026-04-03T00:14:00Z"))

      get shipment_path(id: fulfillment.id)
      # 2026-04-03 00:14 UTC = 2026-04-03 08:14 in Asia/Shanghai (UTC+8)
      expect(response.body).to include("3 Apr, 2026 08:14")
    end
  end

  describe "GET /shipments?archived=true" do
    it "shows only archived shipments" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "ACTIVE1", tracking_status: "InTransit")
      create(:fulfillment, order: order, tracking_number: "ARCH1", tracking_status: "InTransit", archived_at: Time.current)

      get shipments_path(archived: "true")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("ARCH1")
      expect(response.body).not_to include("ACTIVE1")
      expect(response.body).to include("Archived Shipments")
    end

    it "hides archived from default index" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "ACTIVE2", tracking_status: "InTransit")
      create(:fulfillment, order: order, tracking_number: "ARCH2", tracking_status: "InTransit", archived_at: Time.current)

      get shipments_path
      expect(response.body).to include("ACTIVE2")
      expect(response.body).not_to include("ARCH2")
    end
  end

  describe "POST /shipments/bulk_archive" do
    it "archives selected shipments" do
      order = create(:order, customer: customer, shopify_store: store)
      f1 = create(:fulfillment, order: order, tracking_number: "BA1", tracking_status: "InTransit")
      f2 = create(:fulfillment, order: order, tracking_number: "BA2", tracking_status: "InTransit")

      post bulk_archive_shipments_path, params: { ids: [ f1.id, f2.id ] }
      expect(response).to redirect_to(shipments_path)

      expect(f1.reload.archived_at).to be_present
      expect(f2.reload.archived_at).to be_present
    end

    it "does not archive shipments from another company" do
      other_user = create(:user)
      other_store = create(:shopify_store, user: other_user)
      other_customer = create(:customer, shopify_store: other_store)
      other_order = create(:order, customer: other_customer, shopify_store: other_store)
      other_f = create(:fulfillment, order: other_order, tracking_number: "OTHER")

      post bulk_archive_shipments_path, params: { ids: [ other_f.id ] }
      expect(other_f.reload.archived_at).to be_nil
    end
  end

  describe "POST /shipments/bulk_unarchive" do
    it "unarchives selected shipments" do
      order = create(:order, customer: customer, shopify_store: store)
      f1 = create(:fulfillment, order: order, tracking_number: "UA1", tracking_status: "InTransit", archived_at: Time.current)

      post bulk_unarchive_shipments_path, params: { ids: [ f1.id ], archived: "true" }
      expect(response).to redirect_to(shipments_path(archived: "true"))
      expect(f1.reload.archived_at).to be_nil
    end
  end

  describe "POST /shipments/bulk_add_tags" do
    it "adds tags to selected shipments" do
      order = create(:order, customer: customer, shopify_store: store)
      f1 = create(:fulfillment, order: order, tracking_number: "TAG1", tracking_status: "InTransit", tags: [ "existing" ])
      f2 = create(:fulfillment, order: order, tracking_number: "TAG2", tracking_status: "InTransit", tags: [])

      post bulk_add_tags_shipments_path, params: { ids: [ f1.id, f2.id ], tags: [ "new_tag", "another" ] }
      expect(response).to redirect_to(shipments_path)
      expect(f1.reload.tags).to match_array(%w[existing new_tag another])
      expect(f2.reload.tags).to match_array(%w[new_tag another])
    end
  end

  describe "POST /shipments/bulk_remove_tags" do
    it "removes tags from selected shipments" do
      order = create(:order, customer: customer, shopify_store: store)
      f1 = create(:fulfillment, order: order, tracking_number: "RTAG1", tracking_status: "InTransit", tags: %w[keep remove_me])

      post bulk_remove_tags_shipments_path, params: { ids: [ f1.id ], tags: [ "remove_me" ] }
      expect(response).to redirect_to(shipments_path)
      expect(f1.reload.tags).to eq(%w[keep])
    end
  end

  describe "GET /shipments/available_tags" do
    it "returns unique tags as JSON" do
      order = create(:order, customer: customer, shopify_store: store)
      create(:fulfillment, order: order, tracking_number: "AT1", tracking_status: "InTransit", tags: %w[alpha beta])
      create(:fulfillment, order: order, tracking_number: "AT2", tracking_status: "InTransit", tags: %w[beta gamma])

      get available_tags_shipments_path, as: :json
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to match_array(%w[alpha beta gamma])
    end
  end

  describe "POST /shipments/:id/add_tags" do
    it "adds tags to a single shipment" do
      order = create(:order, customer: customer, shopify_store: store)
      f = create(:fulfillment, order: order, tracking_number: "STADD", tracking_status: "InTransit", tags: [ "old" ])

      post add_tags_shipment_path(id: f.id), params: { tags: [ "new" ] }
      expect(response).to redirect_to(shipment_path(id: f.id))
      expect(f.reload.tags).to match_array(%w[old new])
    end
  end

  describe "DELETE /shipments/:id/remove_tag" do
    it "removes a single tag from a shipment" do
      order = create(:order, customer: customer, shopify_store: store)
      f = create(:fulfillment, order: order, tracking_number: "STREM", tracking_status: "InTransit", tags: %w[keep gone])

      delete remove_tag_shipment_path(id: f.id), params: { tag: "gone" }
      expect(response).to redirect_to(shipment_path(id: f.id))
      expect(f.reload.tags).to eq(%w[keep])
    end
  end

  describe "POST /shipments/sync" do
    it "enqueues sync jobs and redirects" do
      store # ensure store exists

      expect {
        post sync_shipments_path
      }.to have_enqueued_job(SyncAllShopifyOrdersJob).with(store.id)

      expect(response).to redirect_to(shipments_path)
    end
  end
end
