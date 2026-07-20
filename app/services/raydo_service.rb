class RaydoService
  class Error < StandardError; end

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
      raise Error, "Raydo auth failed"
    end
    res
  end

  # GET url1/getProductList.htm -> [{product_id, product_shortname}, ...]
  def product_list
    res = get("/getProductList.htm")
    raise Error, "Unexpected product list response" unless res.is_a?(Array)
    res
  end

  private

  def get(path, query = {})
    raise Error, "Raydo base URL is not configured" if @account.url1_base.blank?

    base = @account.url1_base.to_s.chomp("/")
    resp = HTTParty.get("#{base}#{path}", query: query, timeout: 20)
    raise Error, "Raydo HTTP #{resp.code}" unless resp.success?
    parse_response(resp)
  rescue HTTParty::Error, Net::OpenTimeout, Net::ReadTimeout, IO::TimeoutError, Timeout::Error, SocketError, SystemCallError => e
    raise Error, "Raydo connection failed (#{e.class})"
  rescue URI::InvalidURIError, ArgumentError => e
    # Do not interpolate the original exception message here: for a malformed
    # URL, Ruby's URI/HTTParty error messages echo back the full offending
    # URL, which for us includes the Raydo username/password in the query
    # string. Only the exception class is safe to surface.
    raise Error, "Raydo request failed (#{e.class})"
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
