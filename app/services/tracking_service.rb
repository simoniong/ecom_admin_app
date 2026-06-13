class TrackingService
  class MissingApiKeyError < StandardError; end

  BASE_URL = "https://api.17track.net/track/v2.4"
  REGISTER_URL = "#{BASE_URL}/register"
  TRACK_URL = "#{BASE_URL}/gettrackinfo"
  CHANGECARRIER_URL = "#{BASE_URL}/changecarrier"
  CARRIER_BATCH_SIZE = 40

  def initialize(api_key:)
    @api_key = api_key.presence or raise MissingApiKeyError, "17Track API key is required"
  end

  def register(tracking_numbers, carrier: nil, auto_detection: false)
    return [] if tracking_numbers.blank?

    body = tracking_numbers.map do |tn|
      entry = { number: tn }
      if carrier
        entry[:carrier] = carrier
        entry[:auto_detection] = auto_detection
      end
      entry
    end

    response = HTTParty.post(REGISTER_URL, headers: headers, body: body.to_json)
    raise "17Track register error (#{response.code}): #{response.body}" unless response.success?

    # Parse the body explicitly rather than via HTTParty#parsed_response, which
    # depends on a Content-Type header 17Track does not always send.
    data = JSON.parse(response.body)
    data.dig("data", "accepted") || []
  end

  def change_carrier(tracking_numbers, carrier_new:)
    accepted = []
    rejected = []

    Array(tracking_numbers).reject(&:blank?).each_slice(CARRIER_BATCH_SIZE) do |batch|
      body = batch.map { |tn| { number: tn, carrier_new: carrier_new } }
      response = HTTParty.post(CHANGECARRIER_URL, headers: headers, body: body.to_json)
      raise "17Track changecarrier error (#{response.code}): #{response.body}" unless response.success?

      data = JSON.parse(response.body)["data"] || {}
      (data["accepted"] || []).each { |item| accepted << item["number"] }
      (data["rejected"] || []).each { |item| rejected << { number: item["number"], code: item.dig("error", "code") } }
    end

    { accepted: accepted, rejected: rejected }
  end

  def track(tracking_numbers)
    return [] if tracking_numbers.blank?

    body = tracking_numbers.map { |tn| { number: tn } }

    response = HTTParty.post(
      TRACK_URL,
      headers: headers,
      body: body.to_json
    )

    raise "17Track API error (#{response.code}): #{response.body}" unless response.success?

    parse_response(response.parsed_response)
  end

  private

  def headers
    {
      "17token" => @api_key,
      "Content-Type" => "application/json"
    }
  end

  def parse_response(data)
    accepted = data.dig("data", "accepted") || []
    accepted.map do |item|
      track_info = item["track_info"] || {}
      providers = track_info.dig("tracking", "providers") || []
      events = providers.flat_map { |provider| provider["events"] || [] }

      origin_provider = providers.first
      destination_provider = providers.length > 1 ? providers.last : nil

      {
        tracking_number: item["number"],
        status: track_info.dig("latest_status", "status"),
        sub_status: track_info.dig("latest_status", "sub_status"),
        last_event: track_info.dig("latest_event", "description"),
        last_event_time: track_info.dig("latest_event", "time_iso"),
        origin_country: track_info.dig("shipping_info", "shipper_address", "country"),
        destination_country: track_info.dig("shipping_info", "recipient_address", "country"),
        origin_carrier: origin_provider&.dig("provider", "name"),
        destination_carrier: destination_provider&.dig("provider", "name"),
        transit_days: track_info.dig("time_metrics", "days_of_transit"),
        events: events.map do |event|
          {
            description: event["description"],
            time: event["time_iso"],
            location: event["location"]
          }
        end
      }
    end
  end
end
