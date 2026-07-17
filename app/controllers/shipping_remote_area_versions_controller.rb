class ShippingRemoteAreaVersionsController < AdminController
  before_action :require_owner!, only: [ :create, :update, :destroy ]
  before_action :set_version, only: [ :update, :destroy ]

  def index
    versions = current_company.shipping_remote_area_versions.includes(:rules)
    @countries = versions.distinct.pluck(:country_code).sort
    versions = versions.where(country_code: params[:country_code]) if params[:country_code].present?
    @selected_country = params[:country_code]
    @versions = versions.order(country_code: :asc, effective_from: :desc)
  end

  def create
    version = current_company.shipping_remote_area_versions.new(version_params)
    if version.save
      redirect_to shipping_remote_area_versions_path, notice: t("remote_areas.version_created")
    else
      redirect_to shipping_remote_area_versions_path, alert: version.errors.full_messages.join(", ")
    end
  end

  def update
    if @version.update(version_params)
      redirect_to shipping_remote_area_versions_path, notice: t("remote_areas.version_updated")
    else
      redirect_to shipping_remote_area_versions_path, alert: @version.errors.full_messages.join(", ")
    end
  end

  def destroy
    @version.destroy
    redirect_to shipping_remote_area_versions_path, notice: t("remote_areas.version_deleted")
  end

  private

  def set_version
    @version = current_company.shipping_remote_area_versions.find(params[:id])
  end

  def version_params
    params.require(:shipping_remote_area_version).permit(:country_code, :name, :effective_from, :effective_to)
  end

  def require_owner!
    redirect_to(shipping_remote_area_versions_path, alert: t("companies.no_permission")) unless current_membership&.owner?
  end
end
