class ShippingZonePostalRulesController < AdminController
  before_action :require_owner!, only: [ :import ]

  def index
    rules = current_company.shipping_zone_postal_rules
    @summary = rules.group(:country_code, :zone).count.each_with_object({}) do |((cc, zone), n), h|
      (h[cc] ||= {})[zone] = n
    end
    @countries_with_rules = @summary.keys.sort
    @maps = @countries_with_rules.index_with do |cc|
      PostalZoneImporter.dump(country: cc, rules: rules.where(country_code: cc).to_a)
    end
    @available_countries = ShippingRateCardVersion::COUNTRY_CODES - @countries_with_rules
  end

  def import
    result = PostalZoneImporter.new(
      company: current_company, country: params[:country_code], text: params[:text]
    ).call
    if result[:errors].empty?
      redirect_to shipping_zone_postal_rules_path,
                  notice: t("shipping_zone_postal_rules.imported", count: result[:count], country: params[:country_code])
    else
      flash[:import_errors] = result[:errors]
      redirect_to shipping_zone_postal_rules_path,
                  alert: t("shipping_zone_postal_rules.errors_title")
    end
  end

  private

  def require_owner!
    redirect_to(shipping_zone_postal_rules_path, alert: t("companies.no_permission")) unless current_membership&.owner?
  end
end
