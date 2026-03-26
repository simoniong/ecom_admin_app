class TrackingService
  API_URL = "https://api.17track.net/track/v2.2/gettrackinfo"

  def initialize
    @api_key = ENV["SEVENTEEN_TRACK_API_KEY"] || Rails.application.credentials.dig(:seventeen_track, :api_key)
  end

  def track(tracking_numbers)
    return [] if tracking_numbers.blank?

    body = tracking_numbers.map { |tn| { number: tn } }

    response = HTTParty.post(
      API_URL,
      headers: {
        "17token" => @api_key,
        "Content-Type" => "application/json"
      },
      body: body.to_json
    )

    raise "17Track API error (#{response.code}): #{response.body}" unless response.success?

    parse_response(response.parsed_response)
  end

  private

  def parse_response(data)
    accepted = data.dig("data", "accepted") || []
    accepted.map do |item|
      {
        tracking_number: item["number"],
        status: item.dig("track", "e"),
        last_event: item.dig("track", "z0", "z"),
        last_event_time: item.dig("track", "z0", "a"),
        events: (item.dig("track", "z1") || []).map do |event|
          {
            description: event["z"],
            time: event["a"],
            location: event["c"]
          }
        end
      }
    end
  end
end
