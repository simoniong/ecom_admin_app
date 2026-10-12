require "rails_helper"

RSpec.describe GoogleAdsApi do
  let(:api) { described_class.new(refresh_token: "refresh-1", login_customer_id: "6996886629") }
  let(:base) { GoogleAdsApi::BASE_URL }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("GOOGLE_CLIENT_ID").and_return("client-id")
    allow(ENV).to receive(:[]).with("GOOGLE_CLIENT_SECRET").and_return("client-secret")
    allow(ENV).to receive(:[]).with("GOOGLE_ADS_DEVELOPER_TOKEN").and_return("dev-token")
  end

  def stub_refresh(access_token: "access-1")
    stub_request(:post, GoogleAdsApi::TOKEN_URL)
      .with(body: hash_including("grant_type" => "refresh_token", "refresh_token" => "refresh-1"))
      .to_return(status: 200, body: { access_token: access_token }.to_json, headers: { "Content-Type" => "application/json" })
  end

  def json(body)
    { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end

  describe ".authorization_url" do
    it "asks for offline access to the adwords scope with forced consent" do
      url = described_class.authorization_url(redirect_uri: "https://hq.example/google_ads/callback", state: "abc")
      params = Rack::Utils.parse_query(URI(url).query)

      expect(url).to start_with(GoogleAdsApi::AUTH_URL)
      expect(params).to include("client_id" => "client-id", "scope" => GoogleAdsApi::SCOPE,
                                "access_type" => "offline", "prompt" => "consent", "state" => "abc",
                                "redirect_uri" => "https://hq.example/google_ads/callback")
    end
  end

  describe ".exchange_code" do
    it "returns the refresh token" do
      stub_request(:post, GoogleAdsApi::TOKEN_URL)
        .with(body: hash_including("grant_type" => "authorization_code", "code" => "code-1"))
        .to_return(json(access_token: "a", refresh_token: "refresh-new"))

      expect(described_class.exchange_code("code-1", redirect_uri: "https://x/cb")).to eq("refresh-new")
    end

    it "raises AuthError when Google returns no refresh token" do
      stub_request(:post, GoogleAdsApi::TOKEN_URL).to_return(json(access_token: "a"))

      expect { described_class.exchange_code("code-1", redirect_uri: "https://x/cb") }.to raise_error(GoogleAdsApi::AuthError)
    end
  end

  describe "#access_token" do
    it "raises AuthError on invalid_grant (revoked refresh token)" do
      stub_request(:post, GoogleAdsApi::TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant" }.to_json)

      expect { api.access_token }.to raise_error(GoogleAdsApi::AuthError)
    end

    it "raises a plain Error for other token failures" do
      stub_request(:post, GoogleAdsApi::TOKEN_URL).to_return(status: 500, body: "")

      expect { api.access_token }.to raise_error(GoogleAdsApi::Error) { |e| expect(e).not_to be_a(GoogleAdsApi::AuthError) }
    end
  end

  describe "#search" do
    it "sends the developer token and login customer id, and follows pagination" do
      stub_refresh
      stub_request(:post, "#{base}/customers/123/googleAds:search")
        .with(headers: { "Authorization" => "Bearer access-1", "developer-token" => "dev-token", "login-customer-id" => "6996886629" },
              body: { query: "Q" }.to_json)
        .to_return(json(results: [ { "a" => 1 } ], nextPageToken: "p2"))
      stub_request(:post, "#{base}/customers/123/googleAds:search")
        .with(body: { query: "Q", pageToken: "p2" }.to_json)
        .to_return(json(results: [ { "a" => 2 } ]))

      expect(api.search("123", "Q")).to eq([ { "a" => 1 }, { "a" => 2 } ])
    end

    it "raises with the API's status and message on failure" do
      stub_refresh
      stub_request(:post, "#{base}/customers/123/googleAds:search")
        .to_return(status: 403, body: { error: { status: "PERMISSION_DENIED", message: "nope" } }.to_json)

      expect { api.search("123", "Q") }.to raise_error(GoogleAdsApi::Error, /403 PERMISSION_DENIED: nope/)
    end
  end

  describe "#discover_accounts" do
    it "lists the clients under a manager account and accounts reached directly, skipping unreachable ones" do
      stub_refresh
      stub_request(:get, "#{base}/customers:listAccessibleCustomers")
        .to_return(json(resourceNames: %w[customers/6996886629 customers/111 customers/999]))

      stub_request(:post, "#{base}/customers/6996886629/googleAds:search")
        .with { |req| !JSON.parse(req.body)["query"].include?("customer_client") && req.headers["Login-Customer-Id"].nil? }
        .to_return(json(results: [ { customer: { id: "6996886629", descriptiveName: "Ksun Solution", manager: true } } ]))
      stub_request(:post, "#{base}/customers/6996886629/googleAds:search")
        .with { |req| JSON.parse(req.body)["query"].include?("FROM customer_client") && req.headers["Login-Customer-Id"] == "6996886629" }
        .to_return(json(results: [
          { customerClient: { id: "5228314437", descriptiveName: "paintkitstudio", timeZone: "America/New_York", currencyCode: "USD", status: "ENABLED" } }
        ]))
      stub_request(:post, "#{base}/customers/111/googleAds:search")
        .to_return(json(results: [ { customer: { id: "111", descriptiveName: "Direct", manager: false, timeZone: "America/Los_Angeles", currencyCode: "USD", status: "ENABLED" } } ]))
      stub_request(:post, "#{base}/customers/999/googleAds:search")
        .to_return(status: 403, body: { error: { status: "PERMISSION_DENIED", message: "cancelled" } }.to_json)

      accounts = api.discover_accounts

      expect(accounts).to contain_exactly(
        { id: "5228314437", name: "paintkitstudio", time_zone: "America/New_York", currency: "USD", status: "ENABLED", login_customer_id: "6996886629" },
        { id: "111", name: "Direct", time_zone: "America/Los_Angeles", currency: "USD", status: "ENABLED", login_customer_id: nil }
      )
    end
  end
end
