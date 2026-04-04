class TrackingWebhooksController < ActionController::API
  before_action :verify_token

  def receive
    payload = request.request_parameters.presence || JSON.parse(request.raw_post)
    ProcessTrackingWebhookJob.perform_later(payload)
    head :ok
  rescue JSON::ParserError
    head :bad_request
  end

  private

  def verify_token
    expected = ENV["SEVENTEEN_TRACK_WEBHOOK_TOKEN"] || Rails.application.credentials.dig(:seventeen_track, :webhook_token)
    return if expected.blank?

    token = params[:token] || request.headers["X-17Track-Token"]
    head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(token.to_s, expected.to_s)
  end
end
