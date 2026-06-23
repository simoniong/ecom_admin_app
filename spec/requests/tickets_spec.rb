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

    it "renders a copy-to-clipboard affordance for the customer email" do
      customer = create(:customer, first_name: "Jane", last_name: "Buyer", email: "copy-me@example.com")
      ticket = create(:ticket, email_account: email_account, customer: customer)
      sign_in user
      get ticket_path(id: ticket.id)
      expect(response.body).to include('data-clipboard-text-value="copy-me@example.com"')
      expect(response.body).to include("Copy email")
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

    before { email_account.update!(shopify_store: store) }

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

    it "does not return customers from another store in the same company" do
      sibling_store = create(:shopify_store, user: user, company: email_account.company)
      create(:customer, shopify_store: sibling_store, email: "sibling@example.com", first_name: "Sib", last_name: "Ling")
      ticket = create(:ticket, email_account: email_account)
      sign_in user
      get search_customers_ticket_path(id: ticket.id), params: { q: "sibling" }, as: :json
      expect(response.parsed_body).to be_empty
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

    before { email_account.update!(shopify_store: store) }

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

    it "sends instruction to agent for new ticket" do
      ticket = create(:ticket, email_account: email_account, status: :new_ticket)
      sign_in user

      expect {
        post instruct_agent_ticket_path(id: ticket.id), params: { message: "Please draft a refund reply" }
      }.to have_enqueued_job(NotifyAgentJob).with(ticket.id, "revise_draft", "Please draft a refund reply")

      expect(response).to redirect_to(ticket_path(id: ticket.id))
      expect(flash[:notice]).to eq(I18n.t("tickets.show.instruction_sent"))
    end

    it "rejects instruction for closed ticket" do
      ticket = create(:ticket, email_account: email_account, status: :closed)
      sign_in user

      post instruct_agent_ticket_path(id: ticket.id), params: { message: "Do something" }

      expect(response).to redirect_to(ticket_path(id: ticket.id))
      expect(flash[:alert]).to eq(I18n.t("tickets.agent_instruction_not_allowed"))
    end

    it "rejects instruction for draft_confirmed ticket" do
      ticket = create(:ticket, :draft_confirmed, email_account: email_account)
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

  describe "GET /tickets/:id/search_orders" do
    let(:store) { create(:shopify_store, company: email_account.company) }
    let(:customer) { create(:customer, shopify_store: store) }

    before { email_account.update!(shopify_store: store) }

    it "lists the linked customer's orders when query is blank" do
      ticket = create(:ticket, email_account: email_account, customer: customer)
      order = create(:order, customer: customer, name: "#2001")
      sign_in user
      get search_orders_ticket_path(id: ticket.id)
      expect(response.parsed_body.map { |o| o["name"] }).to include("#2001")
    end

    it "searches visible orders by number for an unlinked ticket" do
      ticket = create(:ticket, email_account: email_account, customer: nil,
                      customer_email: "stranger@example.com")
      order = create(:order, customer: customer, name: "#5571")
      sign_in user
      get search_orders_ticket_path(id: ticket.id), params: { q: "5571" }
      expect(response.parsed_body.map { |o| o["id"] }).to include(order.id)
    end

    it "returns an empty array for an unlinked ticket with no query" do
      ticket = create(:ticket, email_account: email_account, customer: nil,
                      customer_email: "stranger@example.com")
      sign_in user
      get search_orders_ticket_path(id: ticket.id)
      expect(response.parsed_body).to eq([])
    end

    it "does not search orders from another store in the same company" do
      sibling_store = create(:shopify_store, company: email_account.company)
      sibling_customer = create(:customer, shopify_store: sibling_store)
      sibling_order = create(:order, customer: sibling_customer, shopify_store: sibling_store, name: "#SIBLING-7777")
      ticket = create(:ticket, email_account: email_account, customer: nil,
                      customer_email: "stranger@example.com")
      sign_in user
      get search_orders_ticket_path(id: ticket.id), params: { q: "7777" }
      expect(response.parsed_body.map { |o| o["id"] }).not_to include(sibling_order.id)
    end
  end

  describe "POST /tickets (new agent thread)" do
    let(:store) { create(:shopify_store, company: email_account.company) }
    let(:customer) { create(:customer, shopify_store: store) }

    it "creates an agent-initiated draft thread for the customer" do
      sign_in user
      expect {
        post tickets_path, params: { ticket: {
          email_account_id: email_account.id,
          customer_id: customer.id,
          customer_email: customer.email,
          customer_name: customer.full_name,
          subject: "Proactive update",
          draft_reply: "Hi, quick update on your order."
        } }
      }.to change(Ticket, :count).by(1)

      ticket = Ticket.order(:created_at).last
      expect(ticket).to be_agent
      expect(ticket).to be_draft
      expect(ticket.gmail_thread_id).to be_nil
      expect(response).to redirect_to(ticket_path(id: ticket.id))
    end

    it "binds an order at creation time" do
      order = create(:order, customer: customer)
      sign_in user
      post tickets_path, params: { ticket: {
        email_account_id: email_account.id,
        customer_id: customer.id, customer_email: customer.email,
        subject: "Re order", draft_reply: "About your order", order_id: order.id
      } }
      expect(Ticket.order(:created_at).last.order).to eq(order)
    end

    it "rejects an email_account the user cannot see" do
      other = create(:email_account)
      sign_in user
      expect {
        post tickets_path, params: { ticket: {
          email_account_id: other.id, customer_email: "x@e.com",
          subject: "x", draft_reply: "y"
        } }
      }.not_to change(Ticket, :count)
      expect(response).to redirect_to(tickets_path)
      expect(flash[:alert]).to eq(I18n.t("tickets.create_failed"))
    end

    it "does not bind an order from another company" do
      other_store = create(:shopify_store, company: create(:company))
      foreign_order = create(:order, customer: create(:customer, shopify_store: other_store))
      sign_in user
      expect {
        post tickets_path, params: { ticket: {
          email_account_id: email_account.id, customer_id: customer.id,
          customer_email: customer.email, subject: "x", draft_reply: "y",
          order_id: foreign_order.id
        } }
      }.not_to change(Ticket, :count)
      expect(response).to redirect_to(tickets_path)
      expect(flash[:alert]).to eq(I18n.t("tickets.create_failed"))
    end

    it "does not link a customer from another company" do
      other_store = create(:shopify_store, company: create(:company))
      foreign_customer = create(:customer, shopify_store: other_store)
      sign_in user
      expect {
        post tickets_path, params: { ticket: {
          email_account_id: email_account.id, customer_id: foreign_customer.id,
          customer_email: "x@e.com", subject: "x", draft_reply: "y"
        } }
      }.not_to change(Ticket, :count)
      expect(response).to redirect_to(tickets_path)
      expect(flash[:alert]).to eq(I18n.t("tickets.create_failed"))
    end

    it "rejects a same-company order that belongs to a different customer" do
      other_customer = create(:customer, shopify_store: store)
      mismatched_order = create(:order, customer: other_customer)
      sign_in user
      expect {
        post tickets_path, params: { ticket: {
          email_account_id: email_account.id, customer_id: customer.id,
          customer_email: customer.email, subject: "x", draft_reply: "y",
          order_id: mismatched_order.id
        } }
      }.not_to change(Ticket, :count)
    end

    it "reverse-links the customer when an unlinked new thread is bound by order" do
      order = create(:order, customer: customer)
      sign_in user
      post tickets_path, params: { ticket: {
        email_account_id: email_account.id, customer_email: "stranger@example.com",
        subject: "x", draft_reply: "y", order_id: order.id
      } }
      ticket = Ticket.order(:created_at).last
      expect(ticket.customer).to eq(customer)
      expect(ticket.customer_email).to eq(customer.email)
    end

    it "derives email/name from the resolved customer, ignoring tampered params" do
      sign_in user
      post tickets_path, params: { ticket: {
        email_account_id: email_account.id, customer_id: customer.id,
        customer_email: "tampered@evil.com", customer_name: "Tampered",
        subject: "x", draft_reply: "y"
      } }
      ticket = Ticket.order(:created_at).last
      expect(ticket.customer_email).to eq(customer.email)
      expect(ticket.customer_name).to eq(customer.full_name)
    end

    it "rejects a new thread with a blank subject" do
      sign_in user
      expect {
        post tickets_path, params: { ticket: {
          email_account_id: email_account.id, customer_id: customer.id,
          customer_email: customer.email, subject: "", draft_reply: "y"
        } }
      }.not_to change(Ticket, :count)
    end
  end

  describe "store scoping" do
    let(:owner) { create(:user) }
    let(:company) { owner.companies.first }
    let!(:store_a) { create(:shopify_store, company: company, user: owner) }
    let!(:store_b) { create(:shopify_store, company: company, user: owner) }
    let!(:account_a) { create(:email_account, company: company, user: owner, shopify_store: store_a) }
    let!(:account_b) { create(:email_account, company: company, user: owner, shopify_store: store_b) }
    let!(:ticket_a) { create(:ticket, email_account: account_a, subject: "Alpha ticket store-A unique-xz9") }
    let!(:ticket_b) { create(:ticket, email_account: account_b, subject: "Bravo ticket store-B unique-xz9") }

    before { sign_in owner }

    it "shows only the selected store's tickets" do
      get tickets_path, params: { store_id: store_a.id }
      expect(response.body).to include("Alpha ticket store-A unique-xz9")
      expect(response.body).not_to include("Bravo ticket store-B unique-xz9")
    end

    it "keeps tickets from store-less email accounts visible under any store" do
      account_none = create(:email_account, company: company, user: owner, shopify_store: nil)
      create(:ticket, email_account: account_none, subject: "Unlinked ticket no-store unique-xz9")

      get tickets_path, params: { store_id: store_a.id }
      expect(response.body).to include("Unlinked ticket no-store unique-xz9")
    end
  end

  describe "GET /tickets/:id show with sibling threads" do
    it "assigns the customer's sibling threads" do
      create(:ticket, email_account: email_account, customer: nil,
             customer_email: "shared@example.com", subject: "First thread")
      current = create(:ticket, email_account: email_account, customer: nil,
                       customer_email: "shared@example.com", subject: "Second thread")
      sign_in user
      get ticket_path(id: current.id)
      expect(response).to have_http_status(:success)
      expect(assigns(:customer_threads).map(&:subject)).to include("First thread", "Second thread")
    end
  end

  describe "PATCH /tickets/:id/bind_order" do
    let(:store) { create(:shopify_store, company: email_account.company) }
    let(:customer) { create(:customer, shopify_store: store) }

    before { email_account.update!(shopify_store: store) }

    it "binds an order to a linked ticket" do
      ticket = create(:ticket, email_account: email_account, customer: customer)
      order = create(:order, customer: customer)
      sign_in user
      patch bind_order_ticket_path(id: ticket.id), params: { order_id: order.id }
      expect(ticket.reload.order).to eq(order)
    end

    it "clears the binding when order_id is blank" do
      order = create(:order, customer: customer)
      ticket = create(:ticket, email_account: email_account, customer: customer, order: order)
      sign_in user
      patch bind_order_ticket_path(id: ticket.id), params: { order_id: "" }
      expect(ticket.reload.order).to be_nil
    end

    it "rejects an order from a different customer when linked" do
      ticket = create(:ticket, email_account: email_account, customer: customer)
      other_order = create(:order, customer: create(:customer, shopify_store: store))
      sign_in user
      patch bind_order_ticket_path(id: ticket.id), params: { order_id: other_order.id }
      expect(ticket.reload.order).to be_nil
    end

    it "reverse-binds: auto-links the customer when the ticket is unlinked" do
      ticket = create(:ticket, email_account: email_account, customer: nil,
                      customer_email: "stranger@example.com")
      order = create(:order, customer: customer)
      sign_in user
      patch bind_order_ticket_path(id: ticket.id), params: { order_id: order.id }
      ticket.reload
      expect(ticket.order).to eq(order)
      expect(ticket.customer).to eq(customer)
      expect(ticket.customer_email).to eq(customer.email)
    end
  end
end
