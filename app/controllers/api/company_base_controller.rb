# Authenticates an AI agent against a COMPANY key, not an EmailAccount key.
# Parcels are company financial data (Order → ShopifyStore → Company); the
# ticket API's EmailAccount principal is the wrong scope for them, so this is a
# separate base class and Api::BaseController stays untouched.
class Api::CompanyBaseController < ActionController::API
  before_action :authenticate_company_key!

  attr_reader :current_company

  private

  def authenticate_company_key!
    token = request.headers["Authorization"]&.delete_prefix("Bearer ")
    return render_unauthorized if token.blank?

    @current_company = Company.find_by(agent_api_key: token)
    render_unauthorized unless @current_company
  end

  def render_unauthorized
    render json: { error: "Unauthorized" }, status: :unauthorized
  end

  def company_stores
    current_company.shopify_stores
  end

  def company_parcels
    Parcel.where(shopify_store_id: company_stores.select(:id))
  end
end
