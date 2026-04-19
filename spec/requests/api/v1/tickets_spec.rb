require "rails_helper"

RSpec.describe "Api::V1::Tickets", type: :request do
  let(:email_account) { create(:email_account) }
  let(:other_email_account) { create(:email_account) }
  let(:auth_headers) { { "Authorization" => "Bearer #{email_account.agent_api_key}" } }

  describe "authentication" do
    it "returns 401 without token" do
      get "/api/v1/tickets"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 with invalid token" do
      get "/api/v1/tickets", headers: { "Authorization" => "Bearer invalid" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 when Authorization header is blank" do
      get "/api/v1/tickets", headers: { "Authorization" => "" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 200 with the email account's agent_api_key" do
      get "/api/v1/tickets", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end

    it "does not accept a key after it has been regenerated" do
      old_key = email_account.agent_api_key
      email_account.regenerate_agent_api_key!
      get "/api/v1/tickets", headers: { "Authorization" => "Bearer #{old_key}" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "email account scoping" do
    it "GET /tickets only returns tickets for the caller's email account" do
      mine = create(:ticket, email_account: email_account, subject: "Mine")
      create(:ticket, email_account: other_email_account, subject: "Theirs")

      get "/api/v1/tickets", headers: auth_headers
      body = JSON.parse(response.body)

      expect(body.map { |t| t["id"] }).to eq([ mine.id ])
    end

    it "GET /tickets/count only counts tickets for the caller's email account" do
      create_list(:ticket, 2, email_account: email_account)
      create_list(:ticket, 3, email_account: other_email_account)

      get "/api/v1/tickets/count", headers: auth_headers
      expect(JSON.parse(response.body)["count"]).to eq(2)
    end

    it "GET /tickets/:id returns 404 for another email account's ticket" do
      foreign = create(:ticket, email_account: other_email_account)

      get "/api/v1/tickets/#{foreign.id}", headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end

    it "POST /tickets/:id/draft_reply returns 404 for another email account's ticket" do
      foreign = create(:ticket, email_account: other_email_account, status: :new_ticket)

      post "/api/v1/tickets/#{foreign.id}/draft_reply",
           params: { draft_reply: "Unauthorized attempt" },
           headers: auth_headers
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload).to be_new_ticket
    end

    it "PATCH /tickets/:id/draft_reply returns 404 for another email account's ticket" do
      foreign = create(:ticket, :draft, email_account: other_email_account)

      patch "/api/v1/tickets/#{foreign.id}/draft_reply",
            params: { draft_reply: "Unauthorized edit" },
            headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/tickets" do
    it "returns all tickets when no status filter" do
      create(:ticket, email_account: email_account, status: :new_ticket, subject: "New one")
      create(:ticket, :draft, email_account: email_account, subject: "Draft one")
      create(:ticket, :closed, email_account: email_account, subject: "Closed one")

      get "/api/v1/tickets", headers: auth_headers
      body = JSON.parse(response.body)

      expect(body.length).to eq(3)
      statuses = body.map { |t| t["status"] }
      expect(statuses).to contain_exactly("new", "draft", "closed")
    end

    it "filters by status when provided" do
      create(:ticket, email_account: email_account, status: :new_ticket, subject: "New one")
      create(:ticket, :draft, email_account: email_account, subject: "Draft one")
      create(:ticket, :closed, email_account: email_account, subject: "Closed one")

      get "/api/v1/tickets", params: { status: "new" }, headers: auth_headers
      body = JSON.parse(response.body)

      expect(body.length).to eq(1)
      expect(body.first["subject"]).to eq("New one")
      expect(body.first["status"]).to eq("new")
    end

    it "ignores invalid status filter and returns all" do
      create(:ticket, email_account: email_account, subject: "Ticket A")
      create(:ticket, :draft, email_account: email_account, subject: "Ticket B")

      get "/api/v1/tickets", params: { status: "bogus" }, headers: auth_headers
      body = JSON.parse(response.body)

      expect(body.length).to eq(2)
    end

    it "does not include messages" do
      ticket = create(:ticket, email_account: email_account)
      create(:message, ticket: ticket, body: "Help me")

      get "/api/v1/tickets", headers: auth_headers
      body = JSON.parse(response.body)

      expect(body.first).not_to have_key("messages")
    end
  end

  describe "GET /api/v1/tickets/count" do
    it "returns total count when no status filter" do
      create_list(:ticket, 3, email_account: email_account, status: :new_ticket)
      create(:ticket, :draft, email_account: email_account)
      create(:ticket, :closed, email_account: email_account)

      get "/api/v1/tickets/count", headers: auth_headers
      body = JSON.parse(response.body)

      expect(response).to have_http_status(:ok)
      expect(body["count"]).to eq(5)
    end

    it "filters count by status when provided" do
      create_list(:ticket, 3, email_account: email_account, status: :new_ticket)
      create(:ticket, :draft, email_account: email_account)
      create(:ticket, :closed, email_account: email_account)

      get "/api/v1/tickets/count", params: { status: "new" }, headers: auth_headers
      body = JSON.parse(response.body)

      expect(response).to have_http_status(:ok)
      expect(body["count"]).to eq(3)
    end

    it "returns 0 when no tickets match status" do
      create(:ticket, :draft, email_account: email_account)

      get "/api/v1/tickets/count", params: { status: "closed" }, headers: auth_headers
      body = JSON.parse(response.body)

      expect(response).to have_http_status(:ok)
      expect(body["count"]).to eq(0)
    end
  end

  describe "GET /api/v1/tickets/:id" do
    it "returns ticket detail with status 'new' for new_ticket" do
      ticket = create(:ticket, email_account: email_account, status: :new_ticket)
      create(:message, ticket: ticket)

      get "/api/v1/tickets/#{ticket.id}", headers: auth_headers
      body = JSON.parse(response.body)

      expect(response).to have_http_status(:ok)
      expect(body["id"]).to eq(ticket.id)
      expect(body["status"]).to eq("new")
      expect(body["messages"]).to be_present
    end

    it "returns ticket with actual status for non-new ticket" do
      ticket = create(:ticket, :draft, email_account: email_account)

      get "/api/v1/tickets/#{ticket.id}", headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("draft")
    end

    it "returns closed ticket with closed status" do
      ticket = create(:ticket, :closed, email_account: email_account)

      get "/api/v1/tickets/#{ticket.id}", headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("closed")
    end

    it "includes customer and orders in detail" do
      customer = create(:customer)
      order = create(:order, customer: customer)
      fulfillment = create(:fulfillment, order: order,
        tracking_status: "InTransit",
        tracking_sub_status: "InTransit_PickedUp",
        origin_country: "CN",
        destination_country: "US",
        shipped_at: "2026-03-31T12:00:00Z",
        delivered_at: nil,
        last_event_at: "2026-04-03T18:00:00Z",
        latest_event_description: "Shipment departed from facility",
        transit_days: 5,
        shopify_data: { "created_at" => "2026-03-31T10:00:00Z" },
        tracking_details: {
          "events" => [
            { "description" => "Shipment departed from facility", "time" => "2026-04-03T18:00:00+08:00", "location" => "Shanghai, CN" },
            { "description" => "Picked up by carrier", "time" => "2026-03-31T14:00:00+08:00", "location" => "Shenzhen, CN" }
          ]
        }
      )
      ticket = create(:ticket, email_account: email_account, customer: customer)

      get "/api/v1/tickets/#{ticket.id}", headers: auth_headers
      body = JSON.parse(response.body)

      expect(body["customer"]["email"]).to eq(customer.email)
      expect(body["orders"].length).to eq(1)

      f = body["orders"].first["fulfillments"].first
      expect(f["tracking_status"]).to eq("InTransit")
      expect(f["tracking_sub_status"]).to eq("InTransit_PickedUp")
      expect(f["origin_country"]).to eq("CN")
      expect(f["destination_country"]).to eq("US")
      expect(f["shipped_at"]).to be_present
      expect(f["shopify_shipped_at"]).to be_present
      expect(f["delivered_at"]).to be_nil
      expect(f["last_event_at"]).to be_present
      expect(f["latest_event_description"]).to eq("Shipment departed from facility")
      expect(f["transit_days"]).to eq(5)

      events = f["tracking_events"]
      expect(events.length).to eq(2)
      expect(events.first["description"]).to eq("Shipment departed from facility")
      expect(events.first["location"]).to eq("Shanghai, CN")
      expect(events.first["time"]).to be_present
      expect(events.last["description"]).to eq("Picked up by carrier")
      expect(events.last["time"]).to be_present
      expect(Time.zone.parse(events.first["time"])).to be >= Time.zone.parse(events.last["time"])
    end
  end

  describe "POST /api/v1/tickets/:id/draft_reply" do
    it "submits draft and transitions to draft status" do
      ticket = create(:ticket, email_account: email_account, status: :new_ticket)

      post "/api/v1/tickets/#{ticket.id}/draft_reply",
           params: { draft_reply: "Thank you for contacting us." },
           headers: auth_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("draft")
      expect(body["draft_reply"]).to eq("Thank you for contacting us.")

      ticket.reload
      expect(ticket).to be_draft
      expect(ticket.draft_reply_at).to be_present
    end

    it "preserves reopened_reason when submitting draft for workflow-triggered ticket" do
      ticket = create(:ticket, email_account: email_account, status: :new_ticket, reopened_reason: "order_shipped")

      post "/api/v1/tickets/#{ticket.id}/draft_reply",
           params: { draft_reply: "Your order has been shipped." },
           headers: auth_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["reopened_reason"]).to eq("order_shipped")
      expect(ticket.reload.reopened_reason).to eq("order_shipped")
    end

    it "returns 422 when ticket is not in new or draft status" do
      ticket = create(:ticket, :closed, email_account: email_account)

      post "/api/v1/tickets/#{ticket.id}/draft_reply",
           params: { draft_reply: "New draft" },
           headers: auth_headers

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 422 when draft_reply is blank" do
      ticket = create(:ticket, email_account: email_account, status: :new_ticket)

      post "/api/v1/tickets/#{ticket.id}/draft_reply",
           params: { draft_reply: "" },
           headers: auth_headers

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 404 for non-existent ticket" do
      post "/api/v1/tickets/00000000-0000-0000-0000-000000000000/draft_reply",
           params: { draft_reply: "Draft" },
           headers: auth_headers

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/tickets/:id/draft_reply" do
    it "updates draft reply when ticket is in draft status" do
      ticket = create(:ticket, :draft, email_account: email_account)

      patch "/api/v1/tickets/#{ticket.id}/draft_reply",
            params: { draft_reply: "Updated draft content" },
            headers: auth_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["draft_reply"]).to eq("Updated draft content")

      ticket.reload
      expect(ticket.draft_reply).to eq("Updated draft content")
      expect(ticket).to be_draft
      expect(ticket.draft_reply_at).to be_within(2.seconds).of(Time.current)
    end

    it "submits draft when ticket is in new_ticket status via PATCH" do
      ticket = create(:ticket, email_account: email_account, status: :new_ticket)

      patch "/api/v1/tickets/#{ticket.id}/draft_reply",
            params: { draft_reply: "New draft via patch" },
            headers: auth_headers

      expect(response).to have_http_status(:ok)
      ticket.reload
      expect(ticket).to be_draft
      expect(ticket.draft_reply).to eq("New draft via patch")
    end

    it "returns 422 when ticket is in draft_confirmed status" do
      ticket = create(:ticket, :draft_confirmed, email_account: email_account)

      patch "/api/v1/tickets/#{ticket.id}/draft_reply",
            params: { draft_reply: "Should fail" },
            headers: auth_headers

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 422 when ticket is closed" do
      ticket = create(:ticket, :closed, email_account: email_account)

      patch "/api/v1/tickets/#{ticket.id}/draft_reply",
            params: { draft_reply: "Should fail" },
            headers: auth_headers

      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 422 when draft_reply is blank" do
      ticket = create(:ticket, :draft, email_account: email_account)

      patch "/api/v1/tickets/#{ticket.id}/draft_reply",
            params: { draft_reply: "" },
            headers: auth_headers

      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
