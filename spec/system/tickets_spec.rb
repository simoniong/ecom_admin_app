require "rails_helper"

RSpec.describe "Tickets", type: :system do
  let!(:user) { create(:user) }
  let!(:email_account) { create(:email_account, user: user) }

  it "shows Kanban board with four swim lanes" do
    sign_in_as(user)
    click_link "Tickets"

    expect(page).to have_text("New")
    expect(page).to have_text("Draft")
    expect(page).to have_text("Confirmed")
    expect(page).to have_text("Closed")
  end

  it "shows tickets in correct swim lanes" do
    create(:ticket, email_account: email_account, subject: "New issue", status: :new_ticket)
    create(:ticket, :draft, email_account: email_account, subject: "Drafted issue")
    create(:ticket, email_account: email_account, subject: "Old issue", status: :closed)

    sign_in_as(user)
    click_link "Tickets"

    within('[data-status="new_ticket"]') do
      expect(page).to have_text("New issue")
      expect(page).not_to have_text("Drafted issue")
    end

    within('[data-status="draft"]') do
      expect(page).to have_text("Drafted issue")
      expect(page).not_to have_text("New issue")
    end

    within('[data-status="closed"]') do
      expect(page).to have_text("Old issue")
    end
  end

  it "navigates to ticket show page from card" do
    ticket = create(:ticket, email_account: email_account, subject: "Help needed")
    create(:message, ticket: ticket, from: "customer@example.com", body: "I need help with my order")

    sign_in_as(user)
    click_link "Tickets"
    click_link "Help needed"

    expect(page).to have_text("Help needed")
    expect(page).to have_text("I need help with my order")
    expect(page).to have_text("Messages")
  end

  it "shows draft reply section for draft tickets" do
    create(:ticket, :draft, email_account: email_account, subject: "Draft ticket",
                     draft_reply: "Agent generated reply")

    sign_in_as(user)
    click_link "Tickets"
    click_link "Draft ticket"

    expect(page).to have_text("Draft Reply")
    expect(page).to have_text("Agent generated reply")
    expect(page).to have_button("Save Draft")
  end

  it "allows editing and saving draft reply" do
    create(:ticket, :draft, email_account: email_account, subject: "Editable draft",
                     draft_reply: "Original draft")

    sign_in_as(user)
    click_link "Tickets"
    click_link "Editable draft"

    fill_in "ticket[draft_reply]", with: "Updated draft content"
    click_button "Save Draft"

    expect(page).to have_text("Draft saved successfully.")
    expect(page).to have_text("Updated draft content")
  end
end
