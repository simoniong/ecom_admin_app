require "rails_helper"

RSpec.describe "LogisticsChannels", type: :request do
  let(:owner) { create(:user) }
  let(:company) { owner.companies.first }
  let(:account) { create(:logistics_account, company: company, url1_base: "http://raydo.test:8082") }

  before { sign_in owner }

  describe "GET /logistics_channels" do
    it "shows a setup hint when no Raydo account is configured yet" do
      get logistics_channels_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("logistics_channels.account_required"))
    end

    it "lists the company's channels" do
      channel = create(:logistics_channel, logistics_account: account, name: "UK Small Packet")
      get logistics_channels_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("UK Small Packet")
      expect(response.body).to include(channel.product_id)
    end
  end

  describe "GET /logistics_channels/new" do
    it "redirects to the account settings page when no account exists" do
      get new_logistics_channel_path
      expect(response).to redirect_to(logistics_account_path)
    end

    it "renders the form when an account exists" do
      account
      get new_logistics_channel_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("logistics_channel_name")
    end
  end

  describe "POST /logistics_channels" do
    it "creates a channel with the picked Raydo product" do
      account
      expect {
        post logistics_channels_path, params: {
          logistics_channel: {
            name: "UK Small Packet", product_id: "P1", product_shortname: "UK 小包",
            shopify_carrier_name: "Other", tracking_url_template: "https://t.17track.net/en#nums=#TrackingNumber#"
          }
        }
      }.to change(LogisticsChannel, :count).by(1)

      expect(response).to redirect_to(logistics_channels_path)
      expect(account.logistics_channels.last.product_id).to eq("P1")
    end

    it "re-renders the form with errors when product_id is missing" do
      account
      expect {
        post logistics_channels_path, params: { logistics_channel: { name: "No product" } }
      }.not_to change(LogisticsChannel, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "GET /logistics_channels/:id/edit and PATCH" do
    it "updates an existing channel" do
      channel = create(:logistics_channel, logistics_account: account, name: "Old name")

      patch logistics_channel_path(id: channel.id), params: { logistics_channel: { name: "New name" } }
      expect(response).to redirect_to(logistics_channels_path)
      expect(channel.reload.name).to eq("New name")
    end
  end

  describe "DELETE /logistics_channels/:id" do
    it "deletes the channel" do
      channel = create(:logistics_channel, logistics_account: account)
      expect {
        delete logistics_channel_path(id: channel.id)
      }.to change(LogisticsChannel, :count).by(-1)
      expect(response).to redirect_to(logistics_channels_path)
    end
  end

  describe "GET /logistics_channels/product_options" do
    it "returns the Raydo product list as JSON" do
      account
      stub_request(:get, "http://raydo.test:8082/getProductList.htm")
        .to_return(body: [ { product_id: "P1", product_shortname: "UK 小包" } ].to_json,
                   headers: { "Content-Type" => "application/json" })

      get product_options_logistics_channels_path, headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.first["product_id"]).to eq("P1")
    end

    it "returns a JSON error (never a 500) when RaydoService raises" do
      account
      stub_request(:get, "http://raydo.test:8082/getProductList.htm")
        .to_return(status: 500, body: "boom")

      get product_options_logistics_channels_path, headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)).to have_key("error")
    end

    it "returns a JSON error (never a 500) when the Raydo request times out" do
      account
      stub_request(:get, "http://raydo.test:8082/getProductList.htm").to_timeout

      get product_options_logistics_channels_path, headers: { "Accept" => "application/json" }
      expect(response).not_to have_http_status(:internal_server_error)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)).to have_key("error")
    end

    it "returns a JSON error (never a 500) when the Raydo connection is refused" do
      account
      stub_request(:get, "http://raydo.test:8082/getProductList.htm").to_raise(Errno::ECONNREFUSED)

      get product_options_logistics_channels_path, headers: { "Accept" => "application/json" }
      expect(response).not_to have_http_status(:internal_server_error)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)).to have_key("error")
    end

    it "returns a JSON error when no account is configured" do
      get product_options_logistics_channels_path, headers: { "Accept" => "application/json" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)).to have_key("error")
    end
  end

  describe "permission gate" do
    it "allows a member granted the logistics_channels permission" do
      m = create(:user)
      create(:membership, user: m, company: company, role: :member, permissions: [ "logistics_channels" ])
      sign_in m
      patch switch_company_path(id: company.id)

      get logistics_channels_path
      expect(response).to have_http_status(:ok)
    end

    it "denies a member without the logistics_channels permission" do
      m = create(:user)
      create(:membership, user: m, company: company, role: :member, permissions: [ "shopify_stores" ])
      sign_in m
      patch switch_company_path(id: company.id)

      get logistics_channels_path
      expect(response).to redirect_to(authenticated_root_path)
    end
  end

  describe "cross-company isolation" do
    it "does not list another company's channels" do
      create(:logistics_channel, logistics_account: account, name: "Company A Channel")

      other_owner = create(:user)
      sign_in other_owner

      get logistics_channels_path
      expect(response.body).not_to include("Company A Channel")
    end

    it "404s reading another company's channel edit form" do
      channel = create(:logistics_channel, logistics_account: account)

      other_owner = create(:user)
      create(:logistics_account, company: other_owner.companies.first)
      sign_in other_owner

      get edit_logistics_channel_path(id: channel.id)
      expect(response).to have_http_status(:not_found)
    end

    it "404s updating another company's channel" do
      channel = create(:logistics_channel, logistics_account: account, name: "Untouched")

      other_owner = create(:user)
      create(:logistics_account, company: other_owner.companies.first)
      sign_in other_owner

      patch logistics_channel_path(id: channel.id), params: { logistics_channel: { name: "Hijacked" } }
      expect(response).to have_http_status(:not_found)
      expect(channel.reload.name).to eq("Untouched")
    end

    it "404s destroying another company's channel" do
      channel = create(:logistics_channel, logistics_account: account)

      other_owner = create(:user)
      create(:logistics_account, company: other_owner.companies.first)
      sign_in other_owner

      expect {
        delete logistics_channel_path(id: channel.id)
      }.not_to change(LogisticsChannel, :count)
      expect(response).to have_http_status(:not_found)
    end

    it "redirects (rather than exposing another company's channel) when the member has no account of their own" do
      channel = create(:logistics_channel, logistics_account: account)

      other_owner = create(:user)
      sign_in other_owner

      get edit_logistics_channel_path(id: channel.id)
      expect(response).to redirect_to(logistics_account_path)
    end
  end
end
