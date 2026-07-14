require "rails_helper"

RSpec.describe "Api::V1::Parcels", type: :request do
  let(:user)    { create(:user) }
  let(:company) { user.companies.first }
  let(:store)   { create(:shopify_store, user: user, company: company, cost_fx_rate: 7.2) }
  let(:customer) { create(:customer, shopify_store: store) }
  let!(:order)   { create(:order, customer: customer, shopify_store: store, name: "PKS#3037", estimated_shipping_cost: 20) }

  before { company.regenerate_agent_api_key! }

  def auth_headers(key = company.agent_api_key)
    { "Authorization" => "Bearer #{key}" }
  end

  def payload(over = {})
    {
      shopify_store_id: store.id,
      identifier: "XMBDE2012381",
      order_name: "PKS#3037",
      cost_cny: "239.73",
      service_channel: "美国标准（A带电）",
      billed_weight_g: 2421
    }.merge(over)
  end

  describe "authentication" do
    it "rejects a request with no key" do
      get "/api/v1/parcels"
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects an EmailAccount agent key (wrong principal)" do
      account = create(:email_account, company: company, user: user)

      get "/api/v1/parcels", headers: auth_headers(account.agent_api_key)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /api/v1/parcels" do
    it "creates a parcel, links the order and rolls up" do
      expect {
        post "/api/v1/parcels", params: payload, headers: auth_headers
      }.to change(Parcel, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["identifier"]).to eq("XMBDE2012381")
      expect(body["cost_amount"].to_f).to eq(33.30)
      expect(body["order_name"]).to eq("PKS#3037")
      expect(order.reload.actual_shipping_cost).to eq(33.30)
    end

    it "is an upsert — posting the same identifier twice updates, never duplicates" do
      post "/api/v1/parcels", params: payload, headers: auth_headers
      expect {
        post "/api/v1/parcels", params: payload(cost_cny: "100.00"), headers: auth_headers
      }.not_to change(Parcel, :count)

      expect(Parcel.last.cost_cny).to eq(100)
    end

    it "422s when the store has no fx rate" do
      store.update!(cost_fx_rate: nil)
      post "/api/v1/parcels", params: payload, headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "404s for a store outside the company" do
      other = create(:shopify_store, user: create(:user), cost_fx_rate: 7)
      post "/api/v1/parcels", params: payload(shopify_store_id: other.id), headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/parcels" do
    before { post "/api/v1/parcels", params: payload, headers: auth_headers }

    it "lists parcels" do
      get "/api/v1/parcels", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).size).to eq(1)
    end

    it "filters by order_name" do
      get "/api/v1/parcels", params: { order_name: "PKS#9999" }, headers: auth_headers
      expect(JSON.parse(response.body)).to be_empty
    end

    it "filters unmatched" do
      post "/api/v1/parcels", params: payload(identifier: "ORPHAN1", order_name: "PKS#9999"), headers: auth_headers

      get "/api/v1/parcels", params: { unmatched: "true" }, headers: auth_headers

      body = JSON.parse(response.body)
      expect(body.map { |p| p["identifier"] }).to eq([ "ORPHAN1" ])
    end
  end

  describe "GET /api/v1/parcels/:identifier" do
    before { post "/api/v1/parcels", params: payload, headers: auth_headers }

    it "returns the parcel" do
      get "/api/v1/parcels/XMBDE2012381", headers: auth_headers
      expect(JSON.parse(response.body)["identifier"]).to eq("XMBDE2012381")
    end

    it "404s for an unknown identifier" do
      get "/api/v1/parcels/NOPE", headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/v1/parcels/:identifier" do
    before { post "/api/v1/parcels", params: payload, headers: auth_headers }

    it "updates the cost and re-rolls up" do
      patch "/api/v1/parcels/XMBDE2012381", params: { cost_cny: "72.00" }, headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(order.reload.actual_shipping_cost).to eq(10)
    end
  end

  describe "GET /api/v1/orders/:name/shipping" do
    before { post "/api/v1/parcels", params: payload, headers: auth_headers }

    it "returns estimated, actual, variance and the parcel breakdown" do
      get "/api/v1/orders/#{CGI.escape('PKS#3037')}/shipping", headers: auth_headers

      body = JSON.parse(response.body)
      expect(body["estimated_shipping_cost"].to_f).to eq(20.0)
      expect(body["actual_shipping_cost"].to_f).to eq(33.30)
      expect(body["variance"].to_f).to eq(13.30)
      expect(body["parcels"].size).to eq(1)
    end

    it "404s for an unknown order" do
      get "/api/v1/orders/PKS%239999/shipping", headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
