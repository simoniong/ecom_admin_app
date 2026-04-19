class Api::BaseController < ActionController::API
  before_action :authenticate_api_key!

  attr_reader :current_email_account

  private

  def authenticate_api_key!
    token = request.headers["Authorization"]&.delete_prefix("Bearer ")

    if token.blank?
      render json: { error: "Unauthorized" }, status: :unauthorized
      return
    end

    @current_email_account = EmailAccount.find_by(agent_api_key: token)

    unless @current_email_account
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end
end
