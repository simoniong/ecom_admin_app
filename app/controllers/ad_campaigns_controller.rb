class AdCampaignsController < AdminController
  SORTABLE_COLUMNS = %w[
    daily_budget impressions clicks ctr cpc
    add_to_cart atc_click_rate cost_per_atc
    checkout_initiated checkout_atc_rate cost_per_checkout
    purchases purchase_checkout_rate purchase_click_rate cost_per_purchase
    spend conversion_value roas
  ].freeze

  def index
    @shopify_stores = current_user.shopify_stores.order(:shop_domain)
    @show_store_selector = @shopify_stores.size > 1

    if params[:shopify_store_id].present?
      @selected_store = @shopify_stores.find_by(id: params[:shopify_store_id])
    end
    @selected_store ||= @shopify_stores.first

    @ad_accounts = if @selected_store
      current_user.ad_accounts.where(shopify_store: @selected_store).order(:account_name)
    else
      current_user.ad_accounts.order(:account_name)
    end

    @selected_account = if params[:ad_account_id].present? && params[:ad_account_id] != "all"
      @ad_accounts.find_by(id: params[:ad_account_id])
    end

    accounts = @selected_account ? [ @selected_account ] : @ad_accounts

    begin
      @from_date = params[:from_date].present? ? Date.parse(params[:from_date]) : 7.days.ago.to_date
      @to_date = params[:to_date].present? ? Date.parse(params[:to_date]) : Date.current
    rescue Date::Error
      @from_date = 7.days.ago.to_date
      @to_date = Date.current
    end
    date_range = @from_date..@to_date

    @status_filter = params[:status_filter].presence
    @sort_column = SORTABLE_COLUMNS.include?(params[:sort_column]) ? params[:sort_column] : "daily_budget"
    @sort_direction = params[:sort_direction] == "asc" ? "asc" : "desc"

    campaigns = AdCampaign.where(ad_account: accounts).includes(:ad_account)
    if @status_filter == "has_spend"
      campaigns = campaigns.where(
        id: AdCampaignDailyMetric.where(date: date_range).where("spend > 0").select(:ad_campaign_id)
      )
    elsif @status_filter.present?
      campaigns = campaigns.where(status: @status_filter)
    end

    @campaign_metrics = AdCampaign.batch_aggregated_metrics(campaigns.pluck(:id), date_range)

    @campaigns = sort_campaigns(campaigns.to_a)

    build_summary

    load_display_templates
  end

  private

  def sort_campaigns(campaigns)
    direction = @sort_direction == "asc" ? 1 : -1

    campaigns.sort_by do |c|
      m = @campaign_metrics[c.id]
      sort_val = if @sort_column == "daily_budget"
        c.daily_budget.to_f
      else
        m.public_send(@sort_column).to_f
      end
      status_priority = c.status == "active" ? 0 : 1
      [ status_priority, direction * sort_val ]
    end
  end

  def build_summary
    totals = @campaign_metrics.values.each_with_object(
      { impressions: 0, clicks: 0, add_to_cart: 0, checkout_initiated: 0, purchases: 0, spend: 0, conversion_value: 0 }
    ) do |m, acc|
      acc[:impressions] += m.impressions
      acc[:clicks] += m.clicks
      acc[:add_to_cart] += m.add_to_cart
      acc[:checkout_initiated] += m.checkout_initiated
      acc[:purchases] += m.purchases
      acc[:spend] += m.spend.to_f
      acc[:conversion_value] += m.conversion_value.to_f
    end

    @summary_metrics = AdCampaign::CampaignMetrics.new(
      totals[:impressions], totals[:clicks], totals[:add_to_cart],
      totals[:checkout_initiated], totals[:purchases], totals[:spend], totals[:conversion_value]
    )
    @summary_budget = @campaigns.sum(&:daily_budget)
  end

  def load_display_templates
    @templates = current_user.campaign_display_templates.by_last_active
    @active_template = if params[:template_id].present?
      tpl = @templates.find_by(id: params[:template_id])
      tpl&.touch_active!
      tpl
    end
    @active_template ||= @templates.first
  end
end
