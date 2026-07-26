class AdCampaignsController < AdminController
  SORTABLE_COLUMNS = %w[
    daily_budget impressions clicks ctr cpc
    add_to_cart atc_click_rate cost_per_atc
    checkout_initiated checkout_atc_rate cost_per_checkout
    purchases purchase_checkout_rate purchase_click_rate cost_per_purchase
    spend conversion_value roas
  ].freeze

  PER_PAGE_DEFAULT = 50
  PER_PAGE_OPTIONS = [ 25, 50, 100, 200, 300, 500 ].freeze

  def sync
    SyncAdCampaignsJob.perform_later(company_id: current_company.id)
    respond_to do |format|
      format.html { redirect_to ad_campaigns_path, notice: t("ad_campaigns.sync_enqueued") }
      format.json { render json: { message: t("ad_campaigns.sync_enqueued") } }
    end
  end

  def index
    view_scope = selected_view_group || current_company
    base_ad_accounts = view_scope.respond_to?(:ad_accounts) ? view_scope.ad_accounts : visible_ad_accounts

    @selected_store = current_shopify_store

    @ad_accounts = if @selected_store
      base_ad_accounts.where(shopify_store: @selected_store).order(:account_name)
    else
      base_ad_accounts.order(:account_name)
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

    @page = [ params[:page].to_i, 1 ].max
    per_page = Integer(params[:per_page], exception: false)
    @per_page = PER_PAGE_OPTIONS.include?(per_page) ? per_page : PER_PAGE_DEFAULT

    campaigns = AdCampaign.where(ad_account: accounts).includes(:ad_account)
    if @status_filter == "has_spend"
      campaigns = campaigns.where(
        id: AdCampaignDailyMetric.where(date: date_range).where("spend > 0").select(:ad_campaign_id)
      )
    elsif @status_filter.present?
      campaigns = campaigns.where(status: @status_filter)
    end

    # Materialise the campaign set ONCE and derive metrics from these same
    # records. SyncAdCampaignsJob (MetaAdsService#sync_campaigns) inserts new
    # AdCampaign rows into this same ad_account scope every hour, and when
    # status_filter == "has_spend" the same job also writes the
    # AdCampaignDailyMetric rows the extra predicate depends on. Either can
    # commit between two separate queries against `campaigns`, so a campaign
    # that appears in a second query but not the first leaves
    # `sort_campaigns` looking up a metrics hash key that was never
    # populated (nil) -> NoMethodError. Querying once removes the window
    # entirely.
    campaigns = campaigns.to_a

    @campaign_metrics = AdCampaign.batch_aggregated_metrics(campaigns, date_range)

    # Sort BEFORE paginating, in Ruby, over the whole set: @sort_column is
    # either the real `daily_budget` column or one of SORTABLE_COLUMNS'
    # CampaignMetrics methods computed from the aggregation query above, not
    # something an `ORDER BY` could express. Slicing a DB-ordered page first
    # and sorting only that page would show arbitrary rows -- e.g. the
    # highest-roas campaign could land on page 4. @total_count is read off
    # this same in-memory array (not a fresh COUNT query against
    # `ad_campaigns`) so the single-SELECT guarantee from 45343f6 still
    # holds.
    sorted = sort_campaigns(campaigns)
    @total_count = sorted.size
    @total_pages = (@total_count.to_f / @per_page).ceil
    @page = [ @page, @total_pages ].min if @total_pages > 0
    @campaigns = sorted.drop((@page - 1) * @per_page).first(@per_page)

    # build_summary must total the entire filtered set, not just the current
    # page -- the summary row is the account-level total, not a per-page
    # subtotal. @campaign_metrics is already keyed by the full materialised
    # `campaigns` array (built above, before sort/slice), so its `.values`
    # naturally cover every campaign regardless of pagination. The budget sum
    # is the one figure build_summary previously read off `@campaigns`
    # itself, which is now the page slice, so it's passed `sorted` (the full
    # set) explicitly instead.
    build_summary(sorted)

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

  def build_summary(all_campaigns)
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
    @summary_budget = all_campaigns.sum(&:daily_budget)
  end

  def load_display_templates
    @templates = current_company.campaign_display_templates.by_last_active
    @active_template = if params[:template_id].present?
      tpl = @templates.find_by(id: params[:template_id])
      tpl&.touch_active!
      tpl
    end
    @active_template ||= @templates.first
  end
end
