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

  # A second, wholly separate tenant. Deliberately reuses the SAME parcel
  # identifier and SAME order name as company A's fixtures above — identifier
  # is only unique per-store and order names aren't globally unique, so this
  # is the realistic collision scenario, not a random-id strawman.
  let(:other_user)     { create(:user) }
  let(:other_company)  { other_user.companies.first }
  let(:other_store)    { create(:shopify_store, user: other_user, company: other_company, cost_fx_rate: 7.2) }
  let(:other_customer) { create(:customer, shopify_store: other_store) }
  let!(:other_order) do
    create(:order, customer: other_customer, shopify_store: other_store, name: "PKS#3037", estimated_shipping_cost: 50)
  end
  let!(:other_parcel) do
    create(:parcel,
      shopify_store: other_store,
      order: other_order,
      identifier: "XMBDE2012381",
      cost_cny: 999.99,
      cost_amount: 138.89)
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

    it "422s and creates nothing when cost_cny is omitted" do
      expect {
        post "/api/v1/parcels", params: payload.except(:cost_cny), headers: auth_headers
      }.not_to change(Parcel, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("cost_cny is required")
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

    it "never returns another company's parcel, even with a colliding identifier" do
      other_parcel # trigger creation

      get "/api/v1/parcels", headers: auth_headers

      ids = JSON.parse(response.body).map { |p| p["id"] }
      expect(ids).to include(Parcel.find_by!(identifier: "XMBDE2012381", shopify_store: store).id)
      expect(ids).not_to include(other_parcel.id)
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

    it "returns this company's parcel, never another company's, on a colliding identifier" do
      other_parcel # trigger creation
      mine = Parcel.find_by!(identifier: "XMBDE2012381", shopify_store: store)

      get "/api/v1/parcels/XMBDE2012381", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["id"]).to eq(mine.id)
    end
  end

  describe "PATCH /api/v1/parcels/:identifier" do
    before { post "/api/v1/parcels", params: payload, headers: auth_headers }

    it "updates the cost and re-rolls up" do
      patch "/api/v1/parcels/XMBDE2012381", params: { cost_cny: "72.00" }, headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(order.reload.actual_shipping_cost).to eq(10)
    end

    it "updates only this company's parcel and leaves another company's colliding parcel untouched" do
      other_parcel # trigger creation
      mine = Parcel.find_by!(identifier: "XMBDE2012381", shopify_store: store)

      patch "/api/v1/parcels/XMBDE2012381", params: { cost_cny: "72.00" }, headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(mine.reload.cost_cny).to eq(72.00)
      expect(other_parcel.reload.cost_cny).to eq(999.99)
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

    it "returns this company's order, never another company's, on a colliding order name" do
      other_order # trigger creation

      get "/api/v1/orders/#{CGI.escape('PKS#3037')}/shipping", headers: auth_headers

      body = JSON.parse(response.body)
      expect(response).to have_http_status(:ok)
      expect(body["estimated_shipping_cost"].to_f).to eq(20.0)
      expect(body["actual_shipping_cost"].to_f).to eq(33.30)
      expect(body["estimated_shipping_cost"].to_f).not_to eq(other_order.estimated_shipping_cost.to_f)
      expect(body["actual_shipping_cost"].to_f).not_to eq(other_order.reload.actual_shipping_cost.to_f)
    end
  end
end
