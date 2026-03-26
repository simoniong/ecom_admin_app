class Api::BaseController < ActionController::API
  before_action :authenticate_api_key!

  private

  def authenticate_api_key!
    token = request.headers["Authorization"]&.delete_prefix("Bearer ")
    expected = Rails.application.credentials.dig(:agent, :api_key)

    unless token.present? && ActiveSupport::SecurityUtils.secure_compare(token, expected)
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end
end
