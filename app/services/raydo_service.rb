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

  # Raydo is inconsistent about its payloads: getProductList returns valid
  # JSON, but selectAuth returns single-quoted pseudo-JSON (e.g.
  # {'customer_id':'6581','ack':'true'}), frequently with a non-JSON
  # content-type. In those cases HTTParty#parsed_response hands back the raw
  # String, which the callers then reject as "not a Hash". Normalize both
  # shapes so a successful auth is recognised.
  def parse_response(resp)
    parsed = resp.parsed_response
    return parsed if parsed.is_a?(Hash) || parsed.is_a?(Array)

    body = resp.body.to_s.strip
    return parsed if body.empty?

    begin
      JSON.parse(body)
    rescue JSON::ParserError
      begin
        # Coerce single-quoted pseudo-JSON into valid JSON. This only runs
        # after strict parsing fails, so it never touches the already-valid
        # double-quoted product list.
        JSON.parse(body.tr("'", '"'))
      rescue JSON::ParserError
        parsed # give up; hand back whatever HTTParty produced
      end
    end
  end
end
