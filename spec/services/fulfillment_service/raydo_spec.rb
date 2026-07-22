require "rails_helper"
RSpec.describe FulfillmentService::Raydo do
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

  it "parses Raydo's single-quoted pseudo-JSON auth response (text/html;charset=GBK)" do
    # Confirmed against the live endpoint: selectAuth returns single-quoted,
    # invalid-JSON with a text/html;charset=GBK content-type, so
    # HTTParty#parsed_response yields a raw String the callers used to reject.
    stub_request(:get, "http://raydo.test:8082/selectAuth.htm").
      with(query: { username: "TEST", password: "123456" }).
      to_return(body: "{'customer_id':'17001','customer_userid':'13461','ack':'true'}",
                headers: { "Content-Type" => "text/html;charset=GBK" })
    res = described_class.new(account).authenticate
    expect(res["ack"]).to eq("true")
    expect(res["customer_id"]).to eq("17001")
    expect(res["customer_userid"]).to eq("13461")
  end

  it "transcodes a GBK-encoded product list (Chinese names) to UTF-8" do
    gbk_body = [ { product_id: "P1", product_shortname: "英国小包" } ].to_json.encode("GBK")
    stub_request(:get, "http://raydo.test:8082/getProductList.htm").
      to_return(body: gbk_body, headers: { "Content-Type" => "text/html;charset=GBK" })
    list = described_class.new(account).product_list
    expect(list.first["product_id"]).to eq("P1")
    expect(list.first["product_shortname"]).to eq("英国小包")
    expect(list.first["product_shortname"].encoding).to eq(Encoding::UTF_8)
  end

  it "raises on ack=false" do
    stub_request(:get, "http://raydo.test:8082/selectAuth.htm").with(query: hash_including({})).
      to_return(body: { ack: "false" }.to_json, headers: { "Content-Type" => "application/json" })
    expect { described_class.new(account).authenticate }.to raise_error(FulfillmentService::Error)
  end

  it "lists products" do
    stub_request(:get, "http://raydo.test:8082/getProductList.htm").
      to_return(body: [ { product_id: "P1", product_shortname: "UK 小包" } ].to_json,
                headers: { "Content-Type" => "application/json" })
    list = described_class.new(account).product_list
    expect(list.first["product_id"]).to eq("P1")
  end

  it "wraps a network timeout as FulfillmentService::Error instead of letting it escape" do
    stub_request(:get, "http://raydo.test:8082/selectAuth.htm").
      with(query: hash_including({})).
      to_timeout

    expect { described_class.new(account).authenticate }.to raise_error(FulfillmentService::Error)
  end

  it "wraps a connection refused error as FulfillmentService::Error instead of letting it escape" do
    stub_request(:get, "http://raydo.test:8082/selectAuth.htm").
      with(query: hash_including({})).
      to_raise(Errno::ECONNREFUSED)

    expect { described_class.new(account).authenticate }.to raise_error(FulfillmentService::Error)
  end

  it "never leaks the username/password (carried in the query string) into the raised error message" do
    stub_request(:get, "http://raydo.test:8082/selectAuth.htm").
      with(query: hash_including({})).
      to_timeout

    begin
      described_class.new(account).authenticate
    rescue FulfillmentService::Error => e
      expect(e.message).not_to include("123456")
      expect(e.message).not_to include("TEST")
      expect(e.message).not_to include("selectAuth.htm")
    end
  end

  describe "malformed or blank url1_base" do
    it "raises FulfillmentService::Error (not URI/ArgumentError) up front when url1_base is blank" do
      blank_account = build(:logistics_account, username: "TEST", password: "123456")
      blank_account.url1_base = ""
      blank_account.save!(validate: false)

      expect { described_class.new(blank_account).authenticate }.to raise_error(FulfillmentService::Error)
      expect { described_class.new(blank_account).product_list }.to raise_error(FulfillmentService::Error)
    end

    it "raises FulfillmentService::Error (not URI::InvalidURIError) for a malformed url1_base" do
      malformed_account = build(:logistics_account, username: "TEST", password: "123456")
      malformed_account.url1_base = "not a url"
      malformed_account.save!(validate: false)

      expect { described_class.new(malformed_account).authenticate }.to raise_error(FulfillmentService::Error)
    end

    it "does not echo the malformed URL (which carries the password) into the error message" do
      malformed_account = build(:logistics_account, username: "TEST", password: "secret-pw")
      malformed_account.url1_base = "not a url"
      malformed_account.save!(validate: false)

      begin
        described_class.new(malformed_account).authenticate
      rescue FulfillmentService::Error => e
        expect(e.message).not_to include("secret-pw")
        expect(e.message).not_to include("not a url")
      end
    end
  end

  describe "#create_order" do
    let(:store)   { create(:shopify_store, package_prefix: "XMBDE", package_number_start: 2013094) }
    let(:channel) { create(:logistics_channel, logistics_account: account, product_id: "P1") }
    let(:account) { create(:logistics_account, url1_base: "http://raydo.test:8082", customer_id: "6581", customer_userid: "6901") }
    let(:package) do
      order = create(:order, shopify_store: store)
      pkg = create(:package, shopify_store: store, order: order, number: 2013094, aasm_state: "pending_process",
                   logistics_channel: channel,
                   shipping_address_snapshot: { "name" => "Amy", "address1" => "1 Rue", "city" => "Paris",
                                                "province" => "IDF", "zip" => "75001", "country_code" => "FR", "phone" => "0102030405" })
      oli = create(:order_line_item, order: order)
      create(:package_item, package: pkg, order_line_item: oli, sku: "A", quantity: 2, refunded_quantity: 0,
             customs_name_zh: "画", customs_name_en: "Painting", declared_value_usd: 20, customs_weight_grams: 500,
             hs_code: "9701", import_hs_code: "9701.10")
      pkg
    end

    it "returns success with an immediate tracking number" do
      stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
        to_return(body: { ack: "true", order_id: "R123", tracking_number: "TN999", is_delay: "N", product_tracknoapitype: "" }.to_json,
                  headers: { "Content-Type" => "application/json" })
      r = described_class.new(account).create_order(package)
      expect(r.success?).to be(true)
      expect(r.deferred?).to be(false)
      expect(r.order_id).to eq("R123")
      expect(r.tracking_number).to eq("TN999")
    end

    it "sends the mapped consignee, product_id, customer ids, reference code and invoice items" do
      stub = stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
        with { |req|
          payload = JSON.parse(CGI.unescape(req.body.sub(/\Aparam=/, "")))
          payload["consignee_name"] == "Amy" && payload["country"] == "FR" &&
            payload["product_id"] == "P1" && payload["customer_id"] == "6581" &&
            payload["customer_userid"] == "6901" && payload["order_customerinvoicecode"] == package.package_code &&
            payload["orderInvoiceParam"].first["invoice_title"] == "Painting" &&
            payload["orderInvoiceParam"].first["sku"] == "画" &&
            payload["orderInvoiceParam"].first["invoice_pcs"] == 2
        }.to_return(body: { ack: "true", order_id: "R1", tracking_number: "T1" }.to_json)
      described_class.new(account).create_order(package)
      expect(stub).to have_been_requested
    end

    it "falls back to authenticate for customer ids when the account has none" do
      account.update!(customer_id: nil, customer_userid: nil)
      stub_request(:get, "http://raydo.test:8082/selectAuth.htm").
        with(query: { username: "TEST", password: "123456" }).
        to_return(body: { customer_id: "AC1", customer_userid: "AU2", ack: "true" }.to_json,
                  headers: { "Content-Type" => "application/json" })
      stub = stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
        with { |req|
          payload = JSON.parse(CGI.unescape(req.body.sub(/\Aparam=/, "")))
          payload["customer_id"] == "AC1" && payload["customer_userid"] == "AU2"
        }.to_return(body: { ack: "true", order_id: "R1", tracking_number: "T1" }.to_json)
      described_class.new(account).create_order(package)
      expect(stub).to have_been_requested
    end

    it "flags deferred when is_delay is Y" do
      stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
        to_return(body: { ack: "true", order_id: "R2", tracking_number: "", is_delay: "Y" }.to_json)
      r = described_class.new(account).create_order(package)
      expect(r.success?).to be(true)
      expect(r.deferred?).to be(true)
      expect(r.order_id).to eq("R2")
    end

    it "flags deferred when product_tracknoapitype is 3" do
      stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
        to_return(body: { ack: "true", order_id: "R3", tracking_number: "X", product_tracknoapitype: "3" }.to_json)
      expect(described_class.new(account).create_order(package).deferred?).to be(true)
    end

    it "returns failure with a urldecoded message on ack=false" do
      stub_request(:post, "http://raydo.test:8082/createOrderApi.htm").
        to_return(body: { ack: "false", message: "%E5%9C%B0%E5%9D%80%E9%94%99%E8%AF%AF" }.to_json) # 地址错误
      r = described_class.new(account).create_order(package)
      expect(r.success?).to be(false)
      expect(r.message).to eq("地址错误")
    end
  end

  describe "#get_tracking_number" do
    it "returns ready with the serve invoice code when status is 200" do
      stub_request(:get, "http://raydo.test:8082/getOrderTrackingNumber.htm").
        with(query: { order_id: "R123" }).
        to_return(body: { status: "200", msg: "获取成功", order_serveinvoicecode: "SF123", express_type: "SF" }.to_json)
      r = described_class.new(account).get_tracking_number("R123")
      expect(r.ready?).to be(true)
      expect(r.tracking_number).to eq("SF123")
      expect(r.carrier).to eq("SF")
    end

    it "is not ready when the serve invoice code is still empty" do
      stub_request(:get, "http://raydo.test:8082/getOrderTrackingNumber.htm").
        with(query: { order_id: "R123" }).
        to_return(body: { status: "200", order_serveinvoicecode: "" }.to_json)
      expect(described_class.new(account).get_tracking_number("R123").ready?).to be(false)
    end
  end

  describe "#label_pdf" do
    let(:account) { create(:logistics_account, url1_base: "http://raydo.test:8082", url2_base: "http://raydo.test:8089") }

    it "fetches the combined PDF for the given order ids and print type" do
      stub = stub_request(:get, "http://raydo.test:8089/order/FastRpt/PDF_NEW.aspx").
        with(query: { "PrintType" => "lab10_10", "order_id" => "R1,R2" }).
        to_return(body: "%PDF-1.4\nlabel", headers: { "Content-Type" => "application/pdf" })
      pdf = described_class.new(account).label_pdf([ "R1", "R2" ], "lab10_10")
      expect(pdf).to start_with("%PDF")
      expect(stub).to have_been_requested
    end

    it "raises when url2_base is not configured" do
      account.update!(url2_base: nil)
      expect { described_class.new(account).label_pdf([ "R1" ], "lab10_10") }.to raise_error(FulfillmentService::Error, /URL2/)
    end

    it "raises on a non-PDF (HTML error page) response" do
      stub_request(:get, "http://raydo.test:8089/order/FastRpt/PDF_NEW.aspx").with(query: hash_including({})).
        to_return(body: "<html>error: order not found</html>", headers: { "Content-Type" => "text/html" })
      expect { described_class.new(account).label_pdf([ "R1" ], "lab10_10") }.to raise_error(FulfillmentService::Error, /non-PDF/)
    end

    it "raises on an HTTP error status" do
      stub_request(:get, "http://raydo.test:8089/order/FastRpt/PDF_NEW.aspx").with(query: hash_including({})).
        to_return(status: 500, body: "err")
      expect { described_class.new(account).label_pdf([ "R1" ], "lab10_10") }.to raise_error(FulfillmentService::Error, /HTTP 500/)
    end
  end
end
