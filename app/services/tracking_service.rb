class TrackingService
  class MissingApiKeyError < StandardError; end

  BASE_URL = "https://api.17track.net/track/v2.4"
  REGISTER_URL = "#{BASE_URL}/register"
  TRACK_URL = "#{BASE_URL}/gettrackinfo"

  def initialize(api_key:)
    @api_key = api_key.presence or raise MissingApiKeyError, "17Track API key is required"
  end

  def register(tracking_numbers)
    return [] if tracking_numbers.blank?

    body = tracking_numbers.map { |tn| { number: tn } }

    response = HTTParty.post(
      REGISTER_URL,
      headers: headers,
      body: body.to_json
    )

    raise "17Track register error (#{response.code}): #{response.body}" unless response.success?

    data = response.parsed_response
    data.dig("data", "accepted") || []
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
