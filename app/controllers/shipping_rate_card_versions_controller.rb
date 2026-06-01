class ShippingRateCardVersionsController < AdminController
  before_action :require_owner!, only: [ :create, :update, :destroy ]
  before_action :set_version, only: [ :update, :destroy ]

  def index
    versions = current_company.shipping_rate_card_versions.includes(:rates)
    @countries = versions.distinct.pluck(:country_code).sort
    @services  = versions.distinct.pluck(:service_type).sort

    versions = versions.where(country_code: params[:country_code]) if params[:country_code].present?
    versions = versions.where(service_type: params[:service_type]) if params[:service_type].present?

    @selected_country = params[:country_code]
    @selected_service = params[:service_type]
    @versions = versions.order(country_code: :asc, service_type: :asc, effective_from: :desc)
  end

  def create
    version = current_company.shipping_rate_card_versions.new(version_params)
    if version.save
      redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.version_created")
    else
      redirect_to shipping_rate_card_versions_path, alert: version.errors.full_messages.join(", ")
    end
  end

  def update
    if @version.update(version_params)
      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.version_updated") }
      end
    else
      respond_to do |format|
        format.turbo_stream { render :update, status: :unprocessable_entity }
        format.html { redirect_to shipping_rate_card_versions_path, alert: @version.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    @version.destroy
    redirect_to shipping_rate_card_versions_path, notice: t("shipping_rate_cards.version_deleted")
  end

  private

  def set_version
    @version = current_company.shipping_rate_card_versions.find(params[:id])
  end

  def version_params
    params.require(:shipping_rate_card_version).permit(
      :name, :country_code, :service_type, :effective_from, :effective_to
    )
  end

  def require_owner!
    redirect_to(shipping_rate_card_versions_path, alert: t("companies.no_permission")) unless current_membership&.owner?
  end
end
