class AdCreativesController < AdminController
  SORTABLE_COLUMNS = %w[
    two_sec_rate p50_rate p75_rate link_ctr
    d1_spend d1_purchases d3_roas d5_roas
    lifetime_spend lifetime_roas
  ].freeze

  BACKFILL_DAYS = 90

  def sync
    visible_ad_accounts.each do |account|
      next unless account.claim_backfill_slot!(manual: true)

      BackfillAdCreativesJob.perform_later(ad_account_id: account.id, days: BACKFILL_DAYS)
    end

    redirect_to ad_creatives_path, notice: t("ad_creatives.sync_enqueued")
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

    load_date_range
    @sort_column = SORTABLE_COLUMNS.include?(params[:sort_column]) ? params[:sort_column] : "lifetime_spend"
    @sort_direction = params[:sort_direction] == "asc" ? "asc" : "desc"

    creatives = AdCreative
      .where(ad_account: accounts)
      .where(id: AdUnit.attributable.select(:ad_creative_id))
      .includes(:ad_account)

    @creative_metrics = AdCreative.batch_aggregated_metrics(creatives.pluck(:id), @from_date..@to_date)
    @creatives = sort_creatives(creatives.to_a)
  end

  private

  def load_date_range
    @from_date = params[:from_date].present? ? Date.parse(params[:from_date]) : 7.days.ago.to_date
    @to_date = params[:to_date].present? ? Date.parse(params[:to_date]) : Date.current
  rescue Date::Error
    @from_date = 7.days.ago.to_date
    @to_date = Date.current
  end

  def sort_creatives(creatives)
    direction = @sort_direction == "asc" ? 1 : -1

    creatives.sort_by do |creative|
      metrics = @creative_metrics[creative.id]
      [ direction * metrics.public_send(@sort_column).to_f, creative.name.to_s ]
    end
  end
end
