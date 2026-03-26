require "rails_helper"

RSpec.describe "Tickets", type: :system do
  let!(:user) { create(:user) }
  let!(:email_account) { create(:email_account, user: user) }

  it "shows empty state when no tickets" do
    sign_in_via_form(user)
    click_link "Tickets"
    expect(page).to have_text("No tickets yet.")
  end

  it "shows ticket list with status badges" do
    create(:ticket, email_account: email_account, subject: "Shipping delay", status: :new_ticket)
    create(:ticket, email_account: email_account, subject: "Refund request", status: :closed)

    sign_in_via_form(user)
    click_link "Tickets"
    expect(page).to have_text("Shipping delay")

    click_link "All"
    expect(page).to have_text("Shipping delay")
    expect(page).to have_text("Refund request")
  end

  it "filters tickets by status" do
    create(:ticket, email_account: email_account, subject: "New issue", status: :new_ticket)
    create(:ticket, email_account: email_account, subject: "Old issue", status: :closed)

    sign_in_via_form(user)
    click_link "Tickets"
    click_link "Closed"

    expect(page).to have_text("Old issue")
    expect(page).not_to have_text("New issue")
  end

  it "navigates to ticket show page with messages" do
    ticket = create(:ticket, email_account: email_account, subject: "Help needed")
    create(:message, ticket: ticket, from: "customer@example.com", body: "I need help with my order")

    sign_in_via_form(user)
    click_link "Tickets"
    click_link "Help needed"

    expect(page).to have_text("Help needed")
    expect(page).to have_text("I need help with my order")
    expect(page).to have_text("Messages")
  end
end
