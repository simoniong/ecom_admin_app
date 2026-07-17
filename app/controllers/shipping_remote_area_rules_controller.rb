class ShippingRemoteAreaRulesController < AdminController
  before_action :require_owner!
  before_action :set_version

  def create
    rule = @version.rules.new(rule_params)
    if rule.save
      redirect_to shipping_remote_area_versions_path, notice: t("remote_areas.rule_created")
    else
      redirect_to shipping_remote_area_versions_path, alert: rule.errors.full_messages.join(", ")
    end
  end

  def destroy
    @version.rules.find(params[:id]).destroy
    redirect_to shipping_remote_area_versions_path, notice: t("remote_areas.rule_deleted")
  end

  def import
    result = RemoteAreaRuleImporter.new(version: @version, text: params[:text]).call
    if result[:errors].empty?
      redirect_to shipping_remote_area_versions_path, notice: t("remote_areas.import_done", count: result[:count])
    else
      flash[:remote_import_errors] = result[:errors]
      redirect_to shipping_remote_area_versions_path, alert: t("remote_areas.import_errors")
    end
  end

  private

  def set_version
    @version = current_company.shipping_remote_area_versions.find(params[:shipping_remote_area_version_id])
  end

  def rule_params
    params.require(:shipping_remote_area_rule).permit(:postal_start, :postal_end, :surcharge_cny, :area_label)
  end

  def require_owner!
    redirect_to(shipping_remote_area_versions_path, alert: t("companies.no_permission")) unless current_membership&.owner?
  end
end
