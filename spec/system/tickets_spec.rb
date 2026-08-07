require "rails_helper"

RSpec.describe "Tickets", type: :system do
  let!(:user) { create(:user) }
  let!(:email_account) { create(:email_account, user: user) }

  it "shows Kanban board with four swim lanes" do
    sign_in_as(user)
    navigate_to_settings_item I18n.t("nav.tickets"), group: I18n.t("nav.customer_support")

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
    navigate_to_settings_item I18n.t("nav.tickets"), group: I18n.t("nav.customer_support")

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
    navigate_to_settings_item I18n.t("nav.tickets"), group: I18n.t("nav.customer_support")
    click_link "Help needed"

    expect(page).to have_text("Help needed")
    expect(page).to have_text("I need help with my order")
    expect(page).to have_text("Messages")
  end

  it "shows draft reply section for draft tickets" do
    create(:ticket, :draft, email_account: email_account, subject: "Draft ticket",
                     draft_reply: "Agent generated reply")

    sign_in_as(user)
    navigate_to_settings_item I18n.t("nav.tickets"), group: I18n.t("nav.customer_support")
    click_link "Draft ticket"

    expect(page).to have_text("Draft Reply")
    expect(page).to have_text("Agent generated reply")
    expect(page).to have_button("Save Draft")
  end

  it "allows editing and saving draft reply" do
    create(:ticket, :draft, email_account: email_account, subject: "Editable draft",
                     draft_reply: "Original draft")

    sign_in_as(user)
    navigate_to_settings_item I18n.t("nav.tickets"), group: I18n.t("nav.customer_support")
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

  describe "message history height on desktop", :js do
    # Regression: the centre pane used to pin the draft/instruct boxes with shrink-0 and
    # hand the leftover height to a flex-1 scroller, which collapsed the history to a
    # ~10px sliver on a laptop viewport. The whole column scrolls as one now.
    let(:ticket) { create(:ticket, :draft, email_account: email_account, subject: "Long history", draft_reply: "Draft body") }

    before do
      12.times do |i|
        create(:message, ticket: ticket, from: "customer@example.com",
                         body: "Message body number #{i}", sent_at: (12 - i).days.ago)
      end
    end

    it "gives the history a readable height instead of a sliver" do
      sign_in_as(user)
      visit ticket_path(id: ticket.id)

      expect(page).to have_css("[data-ticket-messages-list]")
      height = page.evaluate_script(
        "document.querySelector('[data-ticket-messages-list]').getBoundingClientRect().height"
      )
      expect(height).to be > 300
    end

    it "scrolls the whole centre column so the oldest message is reachable" do
      sign_in_as(user)
      visit ticket_path(id: ticket.id)

      pane = "document.querySelector('[data-ticket-center-pane]')"
      expect(page.evaluate_script("#{pane}.scrollHeight > #{pane}.clientHeight")).to be true

      page.execute_script("#{pane}.scrollTop = #{pane}.scrollHeight")
      expect(page).to have_text("Message body number 0")
    end
  end

  describe "collapsible thread pane", :js do
    let(:ticket) { create(:ticket, :draft, email_account: email_account, subject: "Collapse me", draft_reply: "Draft body") }

    def centre_pane_width
      page.evaluate_script(
        "document.querySelector('[data-ticket-center-pane]').getBoundingClientRect().width"
      )
    end

    it "widens the centre column when the thread pane is collapsed" do
      sign_in_as(user)
      visit ticket_path(id: ticket.id)

      expanded_width = centre_pane_width
      expect(page).to have_css("[data-pane-collapse-target='panel']", visible: true)

      find("button[aria-label='#{I18n.t("tickets.show.collapse_threads")}']").click

      expect(page).to have_css("[data-pane-collapse-target='rail']", visible: true)
      expect(centre_pane_width).to be > expanded_width + 200
    end

    it "remembers the collapsed state across reloads and expands again" do
      sign_in_as(user)
      visit ticket_path(id: ticket.id)
      find("button[aria-label='#{I18n.t("tickets.show.collapse_threads")}']").click
      expect(page).to have_css("[data-pane-collapse-target='rail']", visible: true)

      visit ticket_path(id: ticket.id)
      expect(page).to have_css("[data-pane-collapse-target='rail']", visible: true)
      expect(page).to have_css("[data-pane-collapse-target='panel']", visible: false)

      find("button[aria-label='#{I18n.t("tickets.show.expand_threads")}']").click
      expect(page).to have_css("[data-pane-collapse-target='panel']", visible: true)

      visit ticket_path(id: ticket.id)
      expect(page).to have_css("[data-pane-collapse-target='panel']", visible: true)
    end
  end

  describe "Trustpilot BCC opt-in", :js do
    let(:user) { create(:user) }

    it "shows the checkbox only when the store has a Trustpilot address" do
      store = create(:shopify_store, user: user, company: user.companies.first, trustpilot_bcc_email: "shop.com+abc@invite.trustpilot.com")
      account = create(:email_account, user: user, company: user.companies.first, shopify_store: store)
      ticket = create(:ticket, :draft, email_account: account)

      sign_in_as user
      visit ticket_path(id: ticket.id)
      expect(page).to have_content(I18n.t("tickets.show.trustpilot_bcc_label"))
    end

    it "hides the checkbox when the store has no Trustpilot address" do
      store = create(:shopify_store, user: user, company: user.companies.first, trustpilot_bcc_email: nil)
      account = create(:email_account, user: user, company: user.companies.first, shopify_store: store)
      ticket = create(:ticket, :draft, email_account: account)

      sign_in_as user
      visit ticket_path(id: ticket.id)
      expect(page).not_to have_content(I18n.t("tickets.show.trustpilot_bcc_label"))
      expect(page).to have_button(I18n.t("tickets.show.confirm_schedule"))
    end
  end
end
