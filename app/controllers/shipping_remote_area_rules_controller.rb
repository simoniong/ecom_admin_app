class ShippingRemoteAreaRulesController < AdminController
  before_action :require_owner!
  before_action :set_version

  def create
    # A manually-added rule must be normalized the same way the batch importer
    # does (PostalNormalizer.range_for), so that its postal_start/postal_end
    # match the normalized keys that ShippingRemoteAreaVersion#surcharge_for
    # looks up at estimate time. Storing the raw token would never match a real
    # order's normalized postcode.
    attrs = rule_params
    range = PostalNormalizer.range_for(@version.country_code, params.dig(:shipping_remote_area_rule, :postcode))
    if range.nil?
      redirect_to shipping_remote_area_versions_path, alert: t("remote_areas.bad_postcode")
      return
    end

    rule = @version.rules.new(attrs.merge(postal_start: range[0], postal_end: range[1]))
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
    params.require(:shipping_remote_area_rule).permit(:surcharge_cny, :area_label)
  end

  def require_owner!
    redirect_to(shipping_remote_area_versions_path, alert: t("companies.no_permission")) unless current_membership&.owner?
  end
end
