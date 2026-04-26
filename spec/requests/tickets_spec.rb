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

    it "searches tickets by subject" do
      create(:ticket, email_account: email_account, subject: "Shipping delay")
      create(:ticket, email_account: email_account, subject: "Refund request")
      sign_in user
      get tickets_path, params: { q: "shipping" }
      expect(response.body).to include("Shipping delay")
      expect(response.body).not_to include("Refund request")
    end

    it "searches tickets by customer name" do
      create(:ticket, email_account: email_account, customer_name: "Alice Wong", subject: "Issue A")
      create(:ticket, email_account: email_account, customer_name: "Bob Smith", subject: "Issue B")
      sign_in user
      get tickets_path, params: { q: "alice" }
      expect(response.body).to include("Issue A")
      expect(response.body).not_to include("Issue B")
    end

    it "searches tickets by order name" do
      customer = create(:customer)
      create(:order, customer: customer, name: "#1042")
      ticket = create(:ticket, email_account: email_account, customer: customer, subject: "Order issue")
      create(:ticket, email_account: email_account, subject: "Other ticket")
      sign_in user
      get tickets_path, params: { q: "1042" }
      expect(response.body).to include("Order issue")
      expect(response.body).not_to include("Other ticket")
    end

    it "returns all tickets when search is empty" do
      create(:ticket, email_account: email_account, subject: "Ticket A")
      create(:ticket, email_account: email_account, subject: "Ticket B")
      sign_in user
      get tickets_path, params: { q: "" }
      expect(response.body).to include("Ticket A")
      expect(response.body).to include("Ticket B")
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

    it "shows the customer's shipping address when default_address is present" do
      customer = create(:customer,
                        first_name: "Jane", last_name: "Buyer", email: "jane@example.com",
                        shopify_data: {
                          "default_address" => {
                            "address1" => "742 Evergreen Terrace",
                            "city" => "Springfield",
                            "province" => "IL",
                            "zip" => "62704",
                            "country" => "United States"
                          }
                        })
      ticket = create(:ticket, email_account: email_account, customer: customer)
      sign_in user
      get ticket_path(id: ticket.id)
      expect(response.body).to include("Shipping address")
      expect(response.body).to include("742 Evergreen Terrace, Springfield, IL, 62704, United States")
    end

    it "omits the shipping address row when default_address is missing" do
      customer = create(:customer, first_name: "Jane", last_name: "Buyer",
                        email: "jane@example.com", shopify_data: {})
      ticket = create(:ticket, email_account: email_account, customer: customer)
      sign_in user
      get ticket_path(id: ticket.id)
      expect(response.body).not_to include("Shipping address")
    end

    it "renders a copy-to-clipboard affordance for the tracking number" do
      customer = create(:customer, first_name: "Jane", last_name: "Buyer", email: "jane@example.com")
      order = create(:order, customer: customer, name: "#2002")
      create(:fulfillment, order: order, tracking_number: "COPY-ME-123")
      ticket = create(:ticket, email_account: email_account, customer: customer)
      sign_in user
      get ticket_path(id: ticket.id)
      expect(response.body).to include('data-clipboard-text-value="COPY-ME-123"')
      expect(response.body).to include("click->clipboard#copy:stop")
      expect(response.body).to include("Copy tracking number")
    end

    it "shows paid time and fulfillment status for orders" do
      customer = create(:customer, first_name: "Jane", last_name: "Buyer", email: "jane@example.com")
      order = create(:order, customer: customer, name: "#3001", total_price: 79.99,
                     financial_status: "paid", fulfillment_status: "fulfilled",
                     ordered_at: Time.zone.parse("2026-03-28 10:00:00"))
      ticket = create(:ticket, email_account: email_account, customer: customer)
      sign_in user
      get ticket_path(id: ticket.id)
      expect(response.body).to include("#3001")
      expect(response.body).to include("Fulfilled")
    end

    it "shows shipped time from Shopify fulfillment data" do
      customer = create(:customer, first_name: "Jane", last_name: "Buyer", email: "jane@example.com")
      order = create(:order, customer: customer, name: "#3002")
      create(:fulfillment, order: order, tracking_number: "SHIP456",
             tracking_status: "InTransit",
             shopify_data: { "created_at" => "2026-04-01T08:00:00-07:00" })
      ticket = create(:ticket, email_account: email_account, customer: customer)
      sign_in user
      get ticket_path(id: ticket.id)
      expect(response.body).to include("SHIP456")
      expect(response.body).to include("In Transit")
      expect(response.body).to include("Shipped:")
    end

    it "does not show shipped time when shopify_data has no created_at" do
      customer = create(:customer, first_name: "Jane", last_name: "Buyer", email: "jane@example.com")
      order = create(:order, customer: customer, name: "#3004")
      create(:fulfillment, order: order, tracking_number: "SHIP999",
             tracking_status: "InTransit", shopify_data: {})
      ticket = create(:ticket, email_account: email_account, customer: customer)
      sign_in user
      get ticket_path(id: ticket.id)
      expect(response.body).to include("SHIP999")
      expect(response.body).not_to include("Shipped:")
    end

    it "falls back to humanized Shopify status when tracking_status is nil" do
      customer = create(:customer, first_name: "Jane", last_name: "Buyer", email: "jane@example.com")
      order = create(:order, customer: customer, name: "#3003")
      create(:fulfillment, order: order, tracking_number: "SHIP789",
             status: "success", tracking_status: nil)
      ticket = create(:ticket, email_account: email_account, customer: customer)
      sign_in user
      get ticket_path(id: ticket.id)
      expect(response.body).to include("Success")
    end

    it "returns 404 for another user's ticket" do
      other_account = create(:email_account)
      ticket = create(:ticket, email_account: other_account)
      sign_in user
      get ticket_path(id: ticket.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /tickets/:id/search_customers" do
    let(:store) { create(:shopify_store, user: user, company: email_account.company) }

    it "returns matching customers by email" do
      customer = create(:customer, shopify_store: store, email: "alice@example.com", first_name: "Alice", last_name: "Wong")
      ticket = create(:ticket, email_account: email_account)
      sign_in user
      get search_customers_ticket_path(id: ticket.id), params: { q: "alice" }, as: :json
      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      expect(json.length).to eq(1)
      expect(json.first["customer_id"]).to eq(customer.id)
      expect(json.first["customer_email"]).to eq("alice@example.com")
      expect(json.first["match_type"]).to eq("customer")
    end

    it "returns matching customers by name" do
      create(:customer, shopify_store: store, first_name: "Bob", last_name: "Smith")
      ticket = create(:ticket, email_account: email_account)
      sign_in user
      get search_customers_ticket_path(id: ticket.id), params: { q: "Bob Smith" }, as: :json
      json = response.parsed_body
      expect(json.length).to eq(1)
      expect(json.first["customer_name"]).to eq("Bob Smith")
    end

    it "returns customers matched via order name" do
      customer = create(:customer, shopify_store: store, first_name: "Carol")
      create(:order, customer: customer, shopify_store: store, name: "#9001")
      ticket = create(:ticket, email_account: email_account)
      sign_in user
      get search_customers_ticket_path(id: ticket.id), params: { q: "9001" }, as: :json
      json = response.parsed_body
      expect(json.length).to eq(1)
      expect(json.first["match_type"]).to eq("order")
      expect(json.first["order_name"]).to eq("#9001")
    end

    it "does not return customers from other companies" do
      other_store = create(:shopify_store)
      create(:customer, shopify_store: other_store, email: "hidden@example.com")
      ticket = create(:ticket, email_account: email_account)
      sign_in user
      get search_customers_ticket_path(id: ticket.id), params: { q: "hidden" }, as: :json
      json = response.parsed_body
      expect(json).to be_empty
    end

    it "returns empty array for short queries" do
      ticket = create(:ticket, email_account: email_account)
      sign_in user
      get search_customers_ticket_path(id: ticket.id), params: { q: "a" }, as: :json
      expect(response.parsed_body).to be_empty
    end

    it "deduplicates when customer matches both by name and order" do
      customer = create(:customer, shopify_store: store, first_name: "Dan", last_name: "Test")
      create(:order, customer: customer, shopify_store: store, name: "#Dan-order")
      ticket = create(:ticket, email_account: email_account)
      sign_in user
      get search_customers_ticket_path(id: ticket.id), params: { q: "Dan" }, as: :json
      json = response.parsed_body
      customer_ids = json.map { |r| r["customer_id"] }
      expect(customer_ids.uniq.length).to eq(customer_ids.length)
    end
  end

  describe "PATCH /tickets/:id/link_customer" do
    let(:store) { create(:shopify_store, user: user, company: email_account.company) }

    it "links a customer to the ticket" do
      customer = create(:customer, shopify_store: store, first_name: "Eve", last_name: "Lin", email: "eve@example.com")
      ticket = create(:ticket, email_account: email_account)
      sign_in user
      patch link_customer_ticket_path(id: ticket.id), params: { customer_id: customer.id }
      expect(response).to redirect_to(ticket_path(id: ticket.id))
      ticket.reload
      expect(ticket.customer).to eq(customer)
      expect(ticket.customer_name).to eq("Eve Lin")
      expect(ticket.customer_email).to eq("eve@example.com")
    end

    it "changes an existing customer association" do
      old_customer = create(:customer, shopify_store: store, first_name: "Old")
      new_customer = create(:customer, shopify_store: store, first_name: "New", last_name: "Person", email: "new@example.com")
      ticket = create(:ticket, email_account: email_account, customer: old_customer)
      sign_in user
      patch link_customer_ticket_path(id: ticket.id), params: { customer_id: new_customer.id }
      expect(ticket.reload.customer).to eq(new_customer)
    end

    it "rejects linking a customer from another company" do
      other_store = create(:shopify_store)
      other_customer = create(:customer, shopify_store: other_store)
      ticket = create(:ticket, email_account: email_account)
      sign_in user
      patch link_customer_ticket_path(id: ticket.id), params: { customer_id: other_customer.id }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /tickets/:id/instruct_agent" do
    it "sends instruction to agent for draft ticket" do
      ticket = create(:ticket, :draft, email_account: email_account)
      sign_in user

      expect {
        post instruct_agent_ticket_path(id: ticket.id), params: { message: "Make it more polite" }
      }.to have_enqueued_job(NotifyAgentJob).with(ticket.id, "revise_draft", "Make it more polite")

      expect(response).to redirect_to(ticket_path(id: ticket.id))
      expect(flash[:notice]).to eq(I18n.t("tickets.show.instruction_sent"))
    end

    it "rejects instruction for non-draft ticket" do
      ticket = create(:ticket, email_account: email_account, status: :new_ticket)
      sign_in user

      post instruct_agent_ticket_path(id: ticket.id), params: { message: "Do something" }

      expect(response).to redirect_to(ticket_path(id: ticket.id))
      expect(flash[:alert]).to eq(I18n.t("tickets.agent_instruction_not_allowed"))
    end

    it "rejects blank instruction message" do
      ticket = create(:ticket, :draft, email_account: email_account)
      sign_in user

      post instruct_agent_ticket_path(id: ticket.id), params: { message: "  " }

      expect(response).to redirect_to(ticket_path(id: ticket.id))
      expect(flash[:alert]).to eq(I18n.t("tickets.agent_instruction_blank"))
    end

    it "returns 404 for another user's ticket" do
      other_account = create(:email_account)
      ticket = create(:ticket, :draft, email_account: other_account)
      sign_in user

      post instruct_agent_ticket_path(id: ticket.id), params: { message: "Hack" }

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
      ticket = create(:ticket, email_account: email_account, status: :closed)
      sign_in user
      patch ticket_path(id: ticket.id), params: { ticket: { status: "draft_confirmed" } }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "allows new_ticket → closed via JSON (spam)" do
      ticket = create(:ticket, email_account: email_account, status: :new_ticket)
      sign_in user
      patch ticket_path(id: ticket.id), params: { ticket: { status: "closed" } }, as: :json
      expect(response).to have_http_status(:ok)
      expect(ticket.reload).to be_closed
    end

    it "allows closed → new_ticket via JSON (reopen via drag)" do
      ticket = create(:ticket, email_account: email_account, status: :closed)
      sign_in user
      patch ticket_path(id: ticket.id), params: { ticket: { status: "new_ticket" } }, as: :json
      expect(response).to have_http_status(:ok)
      expect(ticket.reload).to be_new_ticket
    end

    it "allows closed → new_ticket via HTML (reopen button)" do
      ticket = create(:ticket, email_account: email_account, status: :closed)
      sign_in user
      patch ticket_path(id: ticket.id), params: { ticket: { status: "new_ticket" } }
      expect(response).to redirect_to(ticket_path(id: ticket.id))
      expect(ticket.reload).to be_new_ticket
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
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "transitions draft → draft_confirmed via HTML and redirects to ticket" do
      ticket = create(:ticket, :draft, email_account: email_account)
      sign_in user
      patch ticket_path(id: ticket.id), params: { ticket: { status: "draft_confirmed" } }
      expect(response).to redirect_to(ticket_path(id: ticket.id))
      expect(ticket.reload).to be_draft_confirmed
    end

    it "shows validation error when transitioning new_ticket → draft without draft_reply" do
      ticket = create(:ticket, email_account: email_account, status: :new_ticket)
      sign_in user
      patch ticket_path(id: ticket.id), params: { ticket: { status: "draft" } }
      expect(response).to redirect_to(ticket_path(id: ticket.id))
      expect(flash[:alert]).to include("Draft reply")
    end

    it "shows alert on invalid HTML status transition" do
      ticket = create(:ticket, email_account: email_account, status: :closed)
      sign_in user
      patch ticket_path(id: ticket.id), params: { ticket: { status: "draft" } }
      expect(response).to redirect_to(ticket_path(id: ticket.id))
      expect(flash[:alert]).to eq(I18n.t("tickets.invalid_transition"))
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
