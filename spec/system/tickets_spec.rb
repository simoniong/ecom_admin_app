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

  it "renders the customer's shipping address in the info panel" do
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
    ticket = create(:ticket, email_account: email_account, customer: customer, subject: "Address ticket")

    sign_in_as(user)
    visit ticket_path(id: ticket.id)

    expect(page).to have_text("Shipping address")
    expect(page).to have_text("742 Evergreen Terrace, Springfield, IL, 62704, United States")
  end

  it "omits the shipping address row when the customer has no default_address" do
    customer = create(:customer, first_name: "Jane", last_name: "Buyer",
                      email: "jane@example.com", shopify_data: {})
    ticket = create(:ticket, email_account: email_account, customer: customer, subject: "No address ticket")

    sign_in_as(user)
    visit ticket_path(id: ticket.id)

    expect(page).not_to have_text("Shipping address")
  end

  it "renders a working copy button next to the customer email" do
    customer = create(:customer, first_name: "Jane", last_name: "Buyer", email: "jane@example.com")
    ticket = create(:ticket, email_account: email_account, customer: customer, subject: "Email copy ticket")

    sign_in_as(user)
    visit ticket_path(id: ticket.id)

    expect(page).to have_css("button[aria-label='Copy email'][data-clipboard-text-value='jane@example.com']")
    first("button[aria-label='Copy email']").click
    expect(page).to have_text("Copied!")
  end

  it "copy tracking-number button does not toggle the fulfillment card" do
    customer = create(:customer, first_name: "Jane", last_name: "Buyer", email: "jane@example.com")
    order = create(:order, customer: customer, name: "#5001")
    create(:fulfillment, order: order, tracking_number: "COPY-TRACK-001",
           tracking_url: "https://carrier.example/track/COPY-TRACK-001")
    ticket = create(:ticket, email_account: email_account, customer: customer, subject: "Tracking ticket")

    sign_in_as(user)
    visit ticket_path(id: ticket.id)

    expect(page).to have_text("COPY-TRACK-001")

    # collapsible_controller toggles the `hidden` class on the content element.
    # We assert against the class list (not Capybara visibility) because system
    # tests in CI don't compile Tailwind, so the `hidden` utility has no styles.
    fulfillment_panel_selector = '[data-collapsible-target="content"][class*="bg-gray-50"]'
    expect(page).to have_css(fulfillment_panel_selector, visible: :all, minimum: 1)

    page.all(fulfillment_panel_selector, visible: :all).each do |panel|
      expect(panel[:class].to_s.split).to include("hidden")
    end

    first("button[aria-label='Copy tracking number']").click

    expect(page).to have_text("Copied!")

    page.all(fulfillment_panel_selector, visible: :all).each do |panel|
      expect(panel[:class].to_s.split).to include("hidden")
    end
  end
end
