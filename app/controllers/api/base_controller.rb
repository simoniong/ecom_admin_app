class Api::BaseController < ActionController::API
  before_action :authenticate_api_key!

  private

  def authenticate_api_key!
    token = request.headers["Authorization"]&.delete_prefix("Bearer ")
    expected = ENV["AGENT_API_KEY"] || Rails.application.credentials.dig(:agent, :api_key)

    if token.blank? || expected.blank?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    unless ActiveSupport::SecurityUtils.secure_compare(token, expected)
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end
end
