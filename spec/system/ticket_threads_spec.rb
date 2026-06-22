require "rails_helper"

RSpec.describe "Ticket threads & order binding", type: :system do
  let(:user) { create(:user) }
  let(:email_account) { create(:email_account, user: user) }
  let(:store) { create(:shopify_store, company: email_account.company) }
  let(:customer) { create(:customer, shopify_store: store) }

  before { driven_by(:rack_test) }

  it "shows sibling threads in the rail and navigates between them" do
    a = create(:ticket, email_account: email_account, customer: customer, subject: "Thread A")
    b = create(:ticket, email_account: email_account, customer: customer, subject: "Thread B")
    sign_in_as(user)
    visit ticket_path(id: a.id)
    expect(page).to have_link("Thread B")
    # The thread list is rendered in both the desktop rail and the mobile bottom sheet.
    # Click the first occurrence to avoid ambiguity.
    first(:link, "Thread B").click
    expect(page).to have_current_path(ticket_path(id: b.id))
  end

  it "shows the bound order tag on a thread" do
    order = create(:order, customer: customer, name: "#1042")
    ticket = create(:ticket, email_account: email_account, customer: customer, order: order)
    sign_in_as(user)
    visit ticket_path(id: ticket.id)
    expect(page).to have_content("#1042")
  end

  it "shows the unlinked banner when no customer is linked" do
    ticket = create(:ticket, email_account: email_account, customer: nil,
                    customer_email: "stranger@example.com")
    sign_in_as(user)
    visit ticket_path(id: ticket.id)
    expect(page).to have_content(I18n.t("tickets.show.unlinked_title"))
  end
end
