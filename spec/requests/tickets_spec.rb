require "rails_helper"

RSpec.describe "Tickets", type: :request do
  let(:user) { create(:user) }
  let(:email_account) { create(:email_account, user: user) }

  describe "GET /tickets" do
    it "returns success for authenticated user" do
      sign_in user
      get tickets_path
      expect(response).to have_http_status(:success)
    end

    it "redirects unauthenticated user" do
      get tickets_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "lists user's tickets" do
      ticket = create(:ticket, email_account: email_account, subject: "My order issue")
      sign_in user
      get tickets_path
      expect(response.body).to include("My order issue")
    end

    it "shows Kanban board with all swim lanes" do
      sign_in user
      get tickets_path
      expect(response.body).to include("New")
      expect(response.body).to include("Draft")
      expect(response.body).to include("Confirmed")
      expect(response.body).to include("Closed")
    end

    it "shows tickets across all swim lanes" do
      create(:ticket, email_account: email_account, status: :new_ticket, subject: "New one")
      create(:ticket, email_account: email_account, status: :closed, subject: "Closed one")
      sign_in user

      get tickets_path
      expect(response.body).to include("New one")
      expect(response.body).to include("Closed one")
    end

    it "does not show other users' tickets" do
      other_account = create(:email_account)
      create(:ticket, email_account: other_account, subject: "Not mine")
      sign_in user
      get tickets_path
      expect(response.body).not_to include("Not mine")
    end
  end

  describe "GET /tickets/:id" do
    it "shows ticket with messages" do
      ticket = create(:ticket, email_account: email_account, subject: "Order question")
      create(:message, ticket: ticket, from: "customer@example.com", body: "Where is my package?")
      sign_in user
      get ticket_path(id: ticket.id)
      expect(response).to have_http_status(:success)
      expect(response.body).to include("Order question")
      expect(response.body).to include("Where is my package?")
    end

    it "shows messages in reverse chronological order" do
      ticket = create(:ticket, email_account: email_account)
      old_msg = create(:message, ticket: ticket, body: "First message", sent_at: 2.hours.ago)
      new_msg = create(:message, ticket: ticket, body: "Latest message", sent_at: 1.minute.ago)
      sign_in user
      get ticket_path(id: ticket.id)
      expect(response.body.index("Latest message")).to be < response.body.index("First message")
    end

    it "shows customer and order info when available" do
      customer = create(:customer, first_name: "Jane", last_name: "Buyer", email: "jane@example.com")
      order = create(:order, customer: customer, name: "#2001", total_price: 59.99)
      create(:fulfillment, order: order, tracking_number: "SHIP123", tracking_company: "FedEx")
      ticket = create(:ticket, email_account: email_account, customer: customer)
      sign_in user
      get ticket_path(id: ticket.id)
      expect(response.body).to include("Jane Buyer")
      expect(response.body).to include("#2001")
      expect(response.body).to include("SHIP123")
    end

    it "returns 404 for another user's ticket" do
      other_account = create(:email_account)
      ticket = create(:ticket, email_account: other_account)
      sign_in user
      get ticket_path(id: ticket.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /tickets/:id" do
    it "updates draft_reply when ticket is in draft status" do
      ticket = create(:ticket, email_account: email_account, status: :draft, draft_reply: "old draft")
      sign_in user
      patch ticket_path(id: ticket.id), params: { ticket: { draft_reply: "updated draft" } }
      expect(response).to redirect_to(ticket_path(id: ticket.id))
      expect(ticket.reload.draft_reply).to eq("updated draft")
    end

    it "updates draft_reply when ticket is in new_ticket status" do
      ticket = create(:ticket, email_account: email_account, status: :new_ticket)
      sign_in user
      patch ticket_path(id: ticket.id), params: { ticket: { draft_reply: "manual draft" } }
      expect(response).to redirect_to(ticket_path(id: ticket.id))
      expect(ticket.reload.draft_reply).to eq("manual draft")
    end

    it "rejects draft update when ticket is closed" do
      ticket = create(:ticket, email_account: email_account, status: :closed)
      sign_in user
      patch ticket_path(id: ticket.id), params: { ticket: { draft_reply: "should fail" } }
      expect(response).to redirect_to(ticket_path(id: ticket.id))
    end

    it "transitions new_ticket → draft via JSON" do
      ticket = create(:ticket, email_account: email_account, status: :new_ticket, draft_reply: "ready")
      sign_in user
      patch ticket_path(id: ticket.id), params: { ticket: { status: "draft" } }, as: :json
      expect(response).to have_http_status(:ok)
      expect(ticket.reload).to be_draft
    end

    it "returns 404 for another user's ticket" do
      other_account = create(:email_account)
      ticket = create(:ticket, email_account: other_account, status: :draft, draft_reply: "draft")
      sign_in user
      patch ticket_path(id: ticket.id), params: { ticket: { draft_reply: "hack" } }
      expect(response).to have_http_status(:not_found)
    end

    it "transitions status from draft to draft_confirmed via JSON" do
      ticket = create(:ticket, :draft, email_account: email_account)
      sign_in user
      patch ticket_path(id: ticket.id), params: { ticket: { status: "draft_confirmed" } }, as: :json
      expect(response).to have_http_status(:ok)
      expect(ticket.reload).to be_draft_confirmed
    end

    it "transitions status from draft_confirmed to draft via JSON" do
      ticket = create(:ticket, :draft_confirmed, email_account: email_account)
      sign_in user
      patch ticket_path(id: ticket.id), params: { ticket: { status: "draft" } }, as: :json
      expect(response).to have_http_status(:ok)
      expect(ticket.reload).to be_draft
    end

    it "rejects invalid status transition via JSON" do
      ticket = create(:ticket, email_account: email_account, status: :new_ticket)
      sign_in user
      patch ticket_path(id: ticket.id), params: { ticket: { status: "closed" } }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "transitions status with position_ids (cross-lane drag)" do
      ticket = create(:ticket, :draft, email_account: email_account)
      other = create(:ticket, :draft_confirmed, email_account: email_account)
      sign_in user
      patch ticket_path(id: ticket.id), params: {
        ticket: { status: "draft_confirmed", position_ids: [ ticket.id, other.id ] }
      }, as: :json
      expect(response).to have_http_status(:ok)
      expect(ticket.reload).to be_draft_confirmed
      expect(ticket.reload.position).to eq(0)
    end

    it "re-renders show on draft update validation failure" do
      ticket = create(:ticket, :draft, email_account: email_account)
      sign_in user
      patch ticket_path(id: ticket.id), params: { ticket: { draft_reply: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "reorders tickets within a lane via JSON" do
      t1 = create(:ticket, email_account: email_account, position: 0)
      t2 = create(:ticket, email_account: email_account, position: 1)
      t3 = create(:ticket, email_account: email_account, position: 2)
      sign_in user

      patch ticket_path(id: t1.id), params: { ticket: { position_ids: [ t3.id, t1.id, t2.id ] } }, as: :json
      expect(response).to have_http_status(:ok)
      expect(t3.reload.position).to eq(0)
      expect(t1.reload.position).to eq(1)
      expect(t2.reload.position).to eq(2)
    end
  end
end
