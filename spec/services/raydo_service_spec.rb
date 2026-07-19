require "rails_helper"
RSpec.describe RaydoService do
  let(:account) { create(:logistics_account, url1_base: "http://raydo.test:8082", username: "TEST", password: "123456") }

  it "authenticates and returns the customer ids" do
    stub_request(:get, "http://raydo.test:8082/selectAuth.htm").
      with(query: { username: "TEST", password: "123456" }).
      to_return(body: { customer_id: "6581", customer_userid: "6901", ack: "true" }.to_json,
                headers: { "Content-Type" => "application/json" })
    res = described_class.new(account).authenticate
    expect(res["customer_id"]).to eq("6581")
    expect(res["customer_userid"]).to eq("6901")
  end

  it "raises on ack=false" do
    stub_request(:get, "http://raydo.test:8082/selectAuth.htm").with(query: hash_including({})).
      to_return(body: { ack: "false" }.to_json, headers: { "Content-Type" => "application/json" })
    expect { described_class.new(account).authenticate }.to raise_error(RaydoService::Error)
  end

  it "lists products" do
    stub_request(:get, "http://raydo.test:8082/getProductList.htm").
      to_return(body: [ { product_id: "P1", product_shortname: "UK 小包" } ].to_json,
                headers: { "Content-Type" => "application/json" })
    list = described_class.new(account).product_list
    expect(list.first["product_id"]).to eq("P1")
  end

  it "wraps a network timeout as RaydoService::Error instead of letting it escape" do
    stub_request(:get, "http://raydo.test:8082/selectAuth.htm").
      with(query: hash_including({})).
      to_timeout

    expect { described_class.new(account).authenticate }.to raise_error(RaydoService::Error)
  end

  it "wraps a connection refused error as RaydoService::Error instead of letting it escape" do
    stub_request(:get, "http://raydo.test:8082/selectAuth.htm").
      with(query: hash_including({})).
      to_raise(Errno::ECONNREFUSED)

    expect { described_class.new(account).authenticate }.to raise_error(RaydoService::Error)
  end

  it "never leaks the username/password (carried in the query string) into the raised error message" do
    stub_request(:get, "http://raydo.test:8082/selectAuth.htm").
      with(query: hash_including({})).
      to_timeout

    begin
      described_class.new(account).authenticate
    rescue RaydoService::Error => e
      expect(e.message).not_to include("123456")
      expect(e.message).not_to include("TEST")
      expect(e.message).not_to include("selectAuth.htm")
    end
  end
end
