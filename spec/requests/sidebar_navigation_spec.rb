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
end
