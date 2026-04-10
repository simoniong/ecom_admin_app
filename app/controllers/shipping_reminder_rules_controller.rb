class ShippingReminderRulesController < AdminController
  def index
    load_all
  end

  def create
    @rule = current_company.shipping_reminder_rules.find_or_initialize_by(rule_type: rule_params[:rule_type])
    @rule.assign_attributes(rule_params)

    if @rule.save
      redirect_to shipping_reminder_rules_path, notice: t("shipping_reminders.rule_updated")
    else
      load_all
      render :index, status: :unprocessable_entity
    end
  end

  def update
    @rule = current_company.shipping_reminder_rules.find(params[:id])

    if @rule.update(update_rule_params)
      redirect_to shipping_reminder_rules_path, notice: t("shipping_reminders.rule_updated")
    else
      load_all
      render :index, status: :unprocessable_entity
    end
  end

  private

  def rule_params
    params.require(:shipping_reminder_rule).permit(:rule_type, :enabled, country_thresholds: [ :country, :days ])
  end

  def update_rule_params
    params.require(:shipping_reminder_rule).permit(:enabled, country_thresholds: [ :country, :days ])
  end

  def load_all
    @rules = ShippingReminderRule::RULE_TYPES.map do |type|
      current_company.shipping_reminder_rules.find_or_initialize_by(rule_type: type)
    end
    @setting = current_company.shipping_reminder_setting ||
               current_company.build_shipping_reminder_setting
    load_country_options
  end

  def load_country_options
    store_ids = current_company.shopify_stores.pluck(:id)
    @top_countries = Fulfillment.joins(:order)
                                .where(orders: { shopify_store_id: store_ids })
                                .where.not(destination_country: [ nil, "" ])
                                .group(:destination_country)
                                .order("count_all DESC")
                                .limit(3)
                                .count
                                .keys

    @all_countries = ISO3166::Country.all.map { |c| [ c.iso_short_name, c.alpha2 ] }
                                        .sort_by(&:first)
  end
end
