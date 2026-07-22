# Raydo (华磊/sz56t) fulfillment adapter. Implements the common
# FulfillmentService interface for the Raydo carrier. Errors surface as the
# shared FulfillmentService::Error so callers stay provider-agnostic.
module FulfillmentService
  class Raydo
    def initialize(account)
      @account = account
    end

    # GET url1/selectAuth.htm?username=&password= -> {customer_id, customer_userid, ack}
    def authenticate
      res = get("/selectAuth.htm", username: @account.username, password: @account.password)
      unless res.is_a?(Hash) && res["ack"].to_s == "true"
        # The response never contains the password (that's only in the request
        # query), so it's safe to log for diagnosing a rejected auth.
        Rails.logger.warn("[Raydo] authentication did not succeed; response=#{res.inspect}")
        raise FulfillmentService::Error, "Raydo auth failed"
      end
      res
    end

    # GET url1/getProductList.htm -> [{product_id, product_shortname}, ...]
    def product_list
      res = get("/getProductList.htm")
      raise FulfillmentService::Error, "Unexpected product list response" unless res.is_a?(Array)
      res
    end

    # Grams -> Raydo weight unit. Doc doesn't state the unit; we send kg
    # (grams / 1000). Confirm with the carrier and adjust this one constant if
    # they expect grams.
    WEIGHT_DIVISOR = 1000.0

    CreateResult = Struct.new(:success, :order_id, :tracking_number, :deferred, :message, keyword_init: true) do
      def success? = !!success
      def deferred? = !!deferred
    end

    TrackResult = Struct.new(:ready, :tracking_number, :carrier, :message, keyword_init: true) do
      def ready? = !!ready
    end

    # POST url1/createOrderApi.htm  body: param=<url-encoded JSON>
    def create_order(package)
      res = post("/createOrderApi.htm", param: order_payload(package).to_json)
      res = {} unless res.is_a?(Hash)
      success = res["ack"].to_s == "true"
      tracking = res["tracking_number"].to_s
      deferred = res["is_delay"].to_s == "Y" || res["product_tracknoapitype"].to_s == "3" || tracking.blank?
      CreateResult.new(
        success: success,
        order_id: res["order_id"].presence,
        tracking_number: tracking.presence,
        deferred: deferred,
        message: success ? nil : urldecode(res["message"])
      )
    end

    # GET url1/getOrderTrackingNumber.htm?order_id=  -> latest-leg tracking no.
    def get_tracking_number(order_id)
      res = get("/getOrderTrackingNumber.htm", order_id: order_id)
      res = {} unless res.is_a?(Hash)
      serve = res["order_serveinvoicecode"].to_s
      TrackResult.new(
        ready: res["status"].to_s == "200" && serve.present?,
        tracking_number: serve.presence,
        carrier: res["express_type"].presence,
        message: res["msg"].presence
      )
    end

    private

    # Customer ids for order creation: prefer the stored ones, else authenticate.
    def customer_ids
      cid = @account.customer_id.presence
      uid = @account.customer_userid.presence
      return [ cid, uid ] if cid && uid

      auth = authenticate
      [ auth["customer_id"], auth["customer_userid"] ]
    end

    def order_payload(package)
      snap = package.shipping_address_snapshot || {}
      cid, uid = customer_ids
      {
        consignee_name: snap["name"],
        consignee_companyname: snap["company"],
        consignee_address: [ snap["address1"], snap["address2"] ].reject(&:blank?).join(" "),
        consignee_telephone: snap["phone"],
        country: snap["country_code"],
        consignee_state: snap["province"],
        consignee_city: snap["city"],
        consignee_postcode: snap["zip"],
        product_id: package.logistics_channel&.product_id,
        order_customerinvoicecode: package.package_code,
        customer_id: cid,
        customer_userid: uid,
        order_piece: 1,
        weight: package_weight_kg(package),
        orderInvoiceParam: package.shippable_items.map { |it| invoice_param(it) }
      }.compact
    end

    def invoice_param(item)
      {
        invoice_title: item.customs_name_en,
        sku: item.customs_name_zh,
        invoice_amount: item.declared_value_usd,
        invoice_weight: to_kg(item.customs_weight_grams),
        invoice_pcs: item.quantity - item.refunded_quantity,
        hs_code: item.hs_code,
        import_hs_code: item.import_hs_code
      }.compact
    end

    def package_weight_kg(package)
      grams = package.shippable_items.sum { |it| it.customs_weight_grams.to_f * (it.quantity - it.refunded_quantity) }
      grams.positive? ? (grams / WEIGHT_DIVISOR).round(3) : nil
    end

    def to_kg(grams)
      grams.present? ? (grams.to_f / WEIGHT_DIVISOR).round(3) : nil
    end

    def urldecode(value)
      return nil if value.blank?

      CGI.unescape(value.to_s)
    rescue ArgumentError
      value.to_s
    end

    # POST form body (application/x-www-form-urlencoded); reuses the GBK/single-
    # quote-tolerant parser. Same credential-safe error handling as #get.
    def post(path, body = {})
      raise FulfillmentService::Error, "Raydo base URL is not configured" if @account.url1_base.blank?

      base = @account.url1_base.to_s.chomp("/")
      resp = HTTParty.post("#{base}#{path}", body: body, timeout: 30)
      raise FulfillmentService::Error, "Raydo HTTP #{resp.code}" unless resp.success?
      parse_response(resp)
    rescue HTTParty::Error, Net::OpenTimeout, Net::ReadTimeout, IO::TimeoutError, Timeout::Error, SocketError, SystemCallError => e
      raise FulfillmentService::Error, "Raydo connection failed (#{e.class})"
    rescue URI::InvalidURIError, ArgumentError => e
      raise FulfillmentService::Error, "Raydo request failed (#{e.class})"
    end

    def get(path, query = {})
      raise FulfillmentService::Error, "Raydo base URL is not configured" if @account.url1_base.blank?

      base = @account.url1_base.to_s.chomp("/")
      resp = HTTParty.get("#{base}#{path}", query: query, timeout: 20)
      raise FulfillmentService::Error, "Raydo HTTP #{resp.code}" unless resp.success?
      parse_response(resp)
    rescue HTTParty::Error, Net::OpenTimeout, Net::ReadTimeout, IO::TimeoutError, Timeout::Error, SocketError, SystemCallError => e
      raise FulfillmentService::Error, "Raydo connection failed (#{e.class})"
    rescue URI::InvalidURIError, ArgumentError => e
      # Do not interpolate the original exception message here: for a malformed
      # URL, Ruby's URI/HTTParty error messages echo back the full offending
      # URL, which for us includes the Raydo username/password in the query
      # string. Only the exception class is safe to surface.
      raise FulfillmentService::Error, "Raydo request failed (#{e.class})"
    end

    # Raydo's payloads are non-standard in two ways, confirmed against the live
    # endpoint (Content-Type: text/html;charset=GBK):
    #   1. selectAuth returns single-quoted pseudo-JSON, e.g.
    #      {'customer_id':'6581','ack':'true'} — invalid JSON, so
    #      HTTParty#parsed_response hands back a raw String the callers reject.
    #   2. bodies are GBK-encoded (getProductList's Chinese product_shortname),
    #      so they must be transcoded to UTF-8 before JSON parsing.
    # Normalize both so a successful response is recognised and readable.
    def parse_response(resp)
      parsed = resp.parsed_response
      return parsed if parsed.is_a?(Hash) || parsed.is_a?(Array)

      body = decode_body(resp)
      return parsed if body.blank?

      begin
        JSON.parse(body)
      rescue JSON::ParserError
        begin
          # Coerce single-quoted pseudo-JSON into valid JSON. This only runs
          # after strict parsing fails, so it never touches an already-valid
          # double-quoted product list.
          JSON.parse(body.tr("'", '"'))
        rescue JSON::ParserError
          parsed # give up; hand back whatever HTTParty produced
        end
      end
    end

    # Transcode the response body to UTF-8 based on the declared charset
    # (Raydo declares GBK). Falls back to the raw body if the charset is
    # unknown/undeclared or transcoding fails.
    def decode_body(resp)
      body = resp.body.to_s
      charset = resp.headers["content-type"].to_s[/charset=([\w-]+)/i, 1]
      decoded =
        if charset && !%w[utf-8 utf8].include?(charset.downcase)
          body.dup.force_encoding(charset).encode("UTF-8", invalid: :replace, undef: :replace)
        else
          body.dup.force_encoding("UTF-8")
        end
      decoded.valid_encoding? ? decoded.strip : body.strip
    rescue EncodingError, ArgumentError
      resp.body.to_s.strip
    end
  end
end
