class RaydoService
  class Error < StandardError; end

  def initialize(account)
    @account = account
  end

  # GET url1/selectAuth.htm?username=&password= -> {customer_id, customer_userid, ack}
  def authenticate
    res = get("/selectAuth.htm", username: @account.username, password: @account.password)
    raise Error, "Raydo auth failed" unless res.is_a?(Hash) && res["ack"].to_s == "true"
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
    resp.parsed_response
  rescue HTTParty::Error, Net::OpenTimeout, Net::ReadTimeout, IO::TimeoutError, Timeout::Error, SocketError, SystemCallError => e
    raise Error, "Raydo connection failed (#{e.class})"
  rescue URI::InvalidURIError, ArgumentError => e
    # Do not interpolate the original exception message here: for a malformed
    # URL, Ruby's URI/HTTParty error messages echo back the full offending
    # URL, which for us includes the Raydo username/password in the query
    # string. Only the exception class is safe to surface.
    raise Error, "Raydo request failed (#{e.class})"
  end
end
