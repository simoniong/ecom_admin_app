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

    it "shows all five children, in order, to the owner" do
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
        shipping_reminder_rules_path
      ])

      expect(menu.text).to include(I18n.t("nav.tracking"))
      expect(menu.text).to include(I18n.t("nav.parcels"))
      expect(menu.text).to include(I18n.t("nav.shipping_rate_cards"))
      expect(menu.text).to include(I18n.t("nav.shipping_zone_postal_rules"))
      expect(menu.text).to include(I18n.t("nav.shipping_reminders"))
    end

    it "shows the Shipping-Variance child but not Rate Cards / Postal Zones for a member with parcels but not shopify_stores" do
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
end
