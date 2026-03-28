class TrackingService
  BASE_URL = "https://api.17track.net/track/v2.4"
  REGISTER_URL = "#{BASE_URL}/register"
  TRACK_URL = "#{BASE_URL}/gettrackinfo"

  def initialize
    @api_key = ENV["SEVENTEEN_TRACK_API_KEY"] || Rails.application.credentials.dig(:seventeen_track, :api_key)
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

      {
        tracking_number: item["number"],
        status: track_info.dig("latest_status", "status"),
        last_event: track_info.dig("latest_event", "description"),
        last_event_time: track_info.dig("latest_event", "time_iso"),
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
