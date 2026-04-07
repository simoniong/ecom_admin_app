require "rails_helper"

RSpec.describe "Api::V1::Tickets", type: :request do
  let(:api_key) { Rails.application.credentials.dig(:agent, :api_key) }
  let(:auth_headers) { { "Authorization" => "Bearer #{api_key}" } }
  let(:email_account) { create(:email_account) }

  describe "authentication" do
    it "returns 401 without token" do
      get "/api/v1/tickets"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 401 with invalid token" do
      get "/api/v1/tickets", headers: { "Authorization" => "Bearer invalid" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 200 with valid token" do
      get "/api/v1/tickets", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /api/v1/tickets" do
    it "returns only new_ticket status tickets" do
      new_ticket = create(:ticket, email_account: email_account, status: :new_ticket, subject: "New one")
      create(:ticket, :draft, email_account: email_account, subject: "Draft one")
      create(:ticket, :closed, email_account: email_account, subject: "Closed one")

      get "/api/v1/tickets", headers: auth_headers
      body = JSON.parse(response.body)

      expect(body.length).to eq(1)
      expect(body.first["subject"]).to eq("New one")
      expect(body.first["id"]).to eq(new_ticket.id)
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
    it "returns count of new_ticket status tickets" do
      create_list(:ticket, 3, email_account: email_account, status: :new_ticket)
      create(:ticket, :draft, email_account: email_account)
      create(:ticket, :closed, email_account: email_account)

      get "/api/v1/tickets/count", headers: auth_headers
      body = JSON.parse(response.body)

      expect(response).to have_http_status(:ok)
      expect(body["count"]).to eq(3)
    end

    it "returns 0 when no new tickets exist" do
      get "/api/v1/tickets/count", headers: auth_headers
      body = JSON.parse(response.body)

      expect(body["count"]).to eq(0)
    end
  end

  describe "GET /api/v1/tickets/:id" do
    it "returns ticket detail for new_ticket" do
      ticket = create(:ticket, email_account: email_account, status: :new_ticket)
      create(:message, ticket: ticket)

      get "/api/v1/tickets/#{ticket.id}", headers: auth_headers
      body = JSON.parse(response.body)

      expect(response).to have_http_status(:ok)
      expect(body["id"]).to eq(ticket.id)
      expect(body["messages"]).to be_present
    end

    it "returns 404 for non-new ticket" do
      ticket = create(:ticket, :draft, email_account: email_account)

      get "/api/v1/tickets/#{ticket.id}", headers: auth_headers
      expect(response).to have_http_status(:not_found)
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

    it "returns 422 when ticket is not new" do
      ticket = create(:ticket, :draft, email_account: email_account)

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
end
