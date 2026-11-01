require "rails_helper"

# Uses the default headless Chrome driver: the confirm step lives in the
# order-picker Stimulus controller, which rack_test can't execute.
RSpec.describe "Force-binding another customer's order to a ticket", type: :system do
  let(:user) { create(:user) }
  let(:email_account) { create(:email_account, user: user) }
  let(:store) { create(:shopify_store, company: email_account.company) }
  let(:customer) { create(:customer, shopify_store: store, first_name: "Donna", last_name: "Wolf") }
  let(:other_customer) do
    create(:customer, shopify_store: store, first_name: "Donna", last_name: "Checkout",
                      email: "checkout@example.com")
  end
  let!(:other_order) { create(:order, customer: other_customer, name: "#FB9001") }
  let!(:ticket) do
    create(:ticket, email_account: email_account, customer: customer,
                    customer_email: "contact@example.com", customer_name: "Donna Wolf")
  end

  before { email_account.update!(shopify_store: store) }

  def open_picker_and_pick_other_order
    sign_in_as(user)
    visit ticket_path(id: ticket.id)
    click_button I18n.t("tickets.show.bind_order_cta")
    find("[data-order-picker-target=input]").fill_in(with: "FB9001")
    find("button[data-order-picker-id-param='#{other_order.id}']", wait: 10).click
  end

  it "asks for confirmation, then binds without changing the ticket's customer" do
    open_picker_and_pick_other_order

    within("[data-testid=force-bind-confirm]") do
      expect(page).to have_content(I18n.t("tickets.show.force_bind_title"))
      expect(page).to have_content("#FB9001")
      expect(page).to have_content("checkout@example.com")
      expect(page).to have_content("contact@example.com")
      click_button I18n.t("tickets.show.force_bind_confirm")
    end

    expect(page).to have_content(I18n.t("tickets.show.order_force_bound"))
    expect(page).to have_css("[data-testid=order-other-customer]", text: "checkout@example.com")

    ticket.reload
    expect(ticket.order).to eq(other_order)
    expect(ticket.customer).to eq(customer)
    expect(ticket.customer_email).to eq("contact@example.com")
  end

  it "does nothing when the confirmation is cancelled" do
    open_picker_and_pick_other_order

    within("[data-testid=force-bind-confirm]") do
      click_button I18n.t("tickets.show.force_bind_cancel")
    end

    expect(page).to have_no_css("[data-testid=force-bind-confirm]", visible: true)
    expect(ticket.reload.order).to be_nil
  end

  it "binds the ticket customer's own order without asking" do
    own_order = create(:order, customer: customer, name: "#FB9002")
    sign_in_as(user)
    visit ticket_path(id: ticket.id)
    click_button I18n.t("tickets.show.bind_order_cta")
    find("button[data-order-picker-id-param='#{own_order.id}']", wait: 10).click

    expect(page).to have_content(I18n.t("tickets.show.order_bound"))
    expect(ticket.reload.order).to eq(own_order)
  end
end
