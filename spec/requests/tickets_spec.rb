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

    it "shows empty state when no tickets" do
      sign_in user
      get tickets_path
      expect(response.body).to include("No tickets yet.")
    end

    it "filters by status" do
      create(:ticket, email_account: email_account, status: :new_ticket, subject: "New one")
      create(:ticket, email_account: email_account, status: :closed, subject: "Closed one")
      sign_in user

      get tickets_path(status: "new_ticket")
      expect(response.body).to include("New one")
      expect(response.body).not_to include("Closed one")
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

    it "returns 404 for another user's ticket" do
      other_account = create(:email_account)
      ticket = create(:ticket, email_account: other_account)
      sign_in user
      get ticket_path(id: ticket.id)
      expect(response).to have_http_status(:not_found)
    end
  end
end
