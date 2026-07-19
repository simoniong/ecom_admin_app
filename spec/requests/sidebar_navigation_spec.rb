require "rails_helper"

# The sidebar (app/views/shared/_sidebar.html.erb) is rendered on every
# authenticated admin page via the admin layout. /parcels has no other
# navigation entry point besides typing the URL or a dashboard button, so its
# link's visibility must follow exactly the same has_permission? gate as the
# controller itself (ParcelsController < AdminController#authorize_page!),
# or a member could either be shown a link to a page they can't open, or be
# unable to find a page they can.
RSpec.describe "Sidebar navigation", type: :request do
  let(:user)    { create(:user) }
  let(:company) { user.companies.first }

  it "shows the shipping-variance link to the owner" do
    sign_in user

    get authenticated_root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(parcels_path)
    expect(response.body).to include(I18n.t("nav.parcels"))
  end

  it "shows the shipping-variance link to a member granted the parcels permission" do
    member = create(:user)
    create(:membership, user: member, company: company, role: :member, permissions: [ "parcels" ])
    sign_in member
    # A member's user factory auto-creates its own (unrelated) owner company,
    # so current_company can't be trusted to default to `company` — select it
    # explicitly rather than relying on companies.first's row order.
    patch switch_company_path(id: company.id)

    get authenticated_root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(parcels_path)
    expect(response.body).to include(I18n.t("nav.parcels"))
  end

  # This is the mutation-test target for the sidebar visibility gate: remove
  # the has_permission?("parcels") guard around the link and this spec must
  # fail, since the member here is granted no permissions at all.
  it "hides the shipping-variance link from a member without the parcels permission" do
    member = create(:user)
    create(:membership, user: member, company: company, role: :member, permissions: [])
    sign_in member
    patch switch_company_path(id: company.id)

    get authenticated_root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(I18n.t("nav.parcels"))
  end

  # The "Shipping" nav group (data-controller="nav-group") replaces the old
  # top-level Shipments entry and gathers Tracking, Shipping Variance,
  # Shipping Rate Cards, Postal Zones and Shipping Reminders under one
  # collapsible header — mirroring how Settings groups its own children.
  describe "Shipping group" do
    def enable_tracking!(company)
      company.update!(
        tracking_enabled: true,
        tracking_api_key: "A" * 32,
        tracking_mode: "new_only",
        tracking_starts_at: Time.current
      )
    end

    it "shows all seven children, in order, to the owner" do
      sign_in user
      enable_tracking!(company)

      get authenticated_root_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      menu = doc.at_css("#shipping-menu")
      expect(menu).to be_present

      hrefs = menu.css("a").map { |a| a["href"] }
      expect(hrefs).to eq([
        shipments_path,
        parcels_path,
        shipping_rate_card_versions_path,
        shipping_zone_postal_rules_path,
        shipping_remote_area_versions_path,
        shipping_reminder_rules_path,
        logistics_channels_path
      ])

      expect(menu.text).to include(I18n.t("nav.tracking"))
      expect(menu.text).to include(I18n.t("nav.parcels"))
      expect(menu.text).to include(I18n.t("nav.shipping_rate_cards"))
      expect(menu.text).to include(I18n.t("nav.shipping_zone_postal_rules"))
      expect(menu.text).to include(I18n.t("nav.shipping_remote_areas"))
      expect(menu.text).to include(I18n.t("nav.shipping_reminders"))
      expect(menu.text).to include(I18n.t("nav.logistics_channels"))
    end

    # Remote Areas shares the shopify_stores gate with Rate Cards and Postal
    # Zones, so a member granted shopify_stores sees all three.
    it "shows Rate Cards, Postal Zones and Remote Areas to a member granted shopify_stores" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "shopify_stores" ])
      sign_in member
      patch switch_company_path(id: company.id)

      get authenticated_root_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      menu = doc.at_css("#shipping-menu")
      expect(menu).to be_present

      expect(menu.text).to include(I18n.t("nav.shipping_rate_cards"))
      expect(menu.text).to include(I18n.t("nav.shipping_zone_postal_rules"))
      expect(menu.text).to include(I18n.t("nav.shipping_remote_areas"))
    end

    it "shows the Shipping-Variance child but not Rate Cards / Postal Zones / Remote Areas for a member with parcels but not shopify_stores" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "parcels" ])
      sign_in member
      patch switch_company_path(id: company.id)

      get authenticated_root_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      menu = doc.at_css("#shipping-menu")
      expect(menu).to be_present

      expect(menu.text).to include(I18n.t("nav.parcels"))
      expect(menu.text).not_to include(I18n.t("nav.shipping_rate_cards"))
      expect(menu.text).not_to include(I18n.t("nav.shipping_zone_postal_rules"))
      expect(menu.text).not_to include(I18n.t("nav.shipping_remote_areas"))
    end

    # Mutation-test target: force the group header to always render (e.g.
    # `<% if true %>` instead of `<% if has_shipping_items %>`) and this spec
    # must fail, since this member is granted none of the five permissions
    # that back the group's children.
    it "hides the Shipping group entirely from a member with none of the shipping permissions" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [])
      sign_in member
      patch switch_company_path(id: company.id)

      get authenticated_root_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("#shipping-menu")).to be_nil
    end

    it "no longer lists Rate Cards, Postal Zones or Reminders under Settings" do
      sign_in user
      enable_tracking!(company)

      get authenticated_root_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      settings_menu = doc.at_css("#settings-menu")
      expect(settings_menu).to be_present

      expect(settings_menu.text).not_to include(I18n.t("nav.shipping_rate_cards"))
      expect(settings_menu.text).not_to include(I18n.t("nav.shipping_zone_postal_rules"))
      expect(settings_menu.text).not_to include(I18n.t("nav.shipping_reminders"))
    end
  end

  # Products is now a collapsible nav-group (like Shipping / Settings / Tickets)
  # gated on a dedicated "products" permission — no longer shopify_stores — with
  # two children: the cost editor (Task 1/2) and Customs Info (Task 3).
  describe "Products group" do
    it "shows the Products group with both children to the owner" do
      sign_in user

      get authenticated_root_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      menu = doc.at_css("#products-menu")
      expect(menu).to be_present

      hrefs = menu.css("a").map { |a| a["href"] }
      expect(hrefs).to include(products_path)
      expect(hrefs).to include(product_customs_path)

      expect(menu.text).to include(I18n.t("nav.product_costs"))
      expect(menu.text).to include(I18n.t("nav.product_customs"))
    end

    it "shows the Products group to a member granted the products permission" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "products" ])
      sign_in member
      patch switch_company_path(id: company.id)

      get authenticated_root_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("#products-menu")).to be_present
    end

    # Mutation-test target: the products/product_variants/product_customs
    # PERMISSION_KEY_MAP entries must point at "products", not "shopify_stores"
    # — a member with only shopify_stores must no longer see this group.
    it "hides the Products group from a member granted only shopify_stores" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "shopify_stores" ])
      sign_in member
      patch switch_company_path(id: company.id)

      get authenticated_root_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("#products-menu")).to be_nil
      expect(response.body).not_to include(I18n.t("nav.product_costs"))
    end

    it "hides the Products group from a member without any permissions" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [])
      sign_in member
      patch switch_company_path(id: company.id)

      get authenticated_root_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("#products-menu")).to be_nil
    end
  end

  # The Tickets entry is a collapsible nav-group (like Shipping / Settings)
  # gathering the ticket list and its Email Workflows automation under one
  # header. Email Workflows was moved here out of the Settings group.
  describe "Tickets group" do
    it "nests the ticket list and Email Workflows under #tickets-menu for the owner" do
      create(:shopify_store, user: user, company: company)
      sign_in user

      get authenticated_root_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      menu = doc.at_css("#tickets-menu")
      expect(menu).to be_present

      hrefs = menu.css("a").map { |a| a["href"] }
      expect(hrefs.first).to eq(tickets_path)
      expect(hrefs).to include(shopify_store_email_workflows_path(company.shopify_stores.first))

      # The group header (Level 1) reads "Customer Support"; the ticket list
      # child link (Level 2) keeps the "Tickets" label.
      header = doc.at_css("button[aria-controls='tickets-menu']")
      expect(header.text).to include(I18n.t("nav.customer_support"))
      expect(header.text).not_to include(I18n.t("nav.tickets"))

      expect(menu.text).to include(I18n.t("nav.tickets"))
      expect(menu.text).to include(I18n.t("nav.email_workflows"))
    end

    it "no longer lists Email Workflows under the Settings group" do
      create(:shopify_store, user: user, company: company)
      sign_in user

      get authenticated_root_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      settings_menu = doc.at_css("#settings-menu")
      expect(settings_menu).to be_present
      expect(settings_menu.text).not_to include(I18n.t("nav.email_workflows"))
    end

    # Email Workflows keeps the shopify_stores gate even inside the Tickets
    # group: EmailWorkflowsController authorizes on shopify_stores, so a member
    # with only tickets permission must not be shown the link.
    it "hides the Email Workflows child from a member with tickets but not shopify_stores" do
      create(:shopify_store, user: user, company: company)
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [ "tickets" ])
      sign_in member
      patch switch_company_path(id: company.id)

      get authenticated_root_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      menu = doc.at_css("#tickets-menu")
      expect(menu).to be_present
      expect(menu.text).to include(I18n.t("nav.tickets"))
      expect(menu.text).not_to include(I18n.t("nav.email_workflows"))
    end

    it "hides the Tickets group entirely from a member without the tickets permission" do
      member = create(:user)
      create(:membership, user: member, company: company, role: :member, permissions: [])
      sign_in member
      patch switch_company_path(id: company.id)

      get authenticated_root_path

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("#tickets-menu")).to be_nil
    end
  end
end
