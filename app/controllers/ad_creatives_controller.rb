class AdCreativesController < AdminController
  SORTABLE_COLUMNS = %w[
    two_sec_rate p50_rate p75_rate link_ctr cpc_link cpc_all cpm
    d1_spend d1_purchases d3_roas d5_roas
    lifetime_spend lifetime_roas
  ].freeze

  BACKFILL_DAYS = 90

  # Claims target exactly the accounts the page is showing. A claim pushes
  # `next_attempt_at` an hour out, so sweeping every visible account would let
  # a sync of store A suppress the automatic heal of an unrelated broken
  # account in store B for an hour.
  def sync
    sync_target_accounts.each do |account|
      next unless account.claim_backfill_slot!(manual: true)

      BackfillAdCreativesJob.perform_later(ad_account_id: account.id, days: BACKFILL_DAYS)
    end

    redirect_to ad_creatives_path, notice: t("ad_creatives.sync_enqueued")
  end

  def index
    @selected_store = current_shopify_store
    @ad_accounts = scoped_ad_accounts
    @selected_account = find_selected_account(@ad_accounts)

    accounts = @selected_account ? [ @selected_account ] : @ad_accounts

    load_date_range
    @sort_column = SORTABLE_COLUMNS.include?(params[:sort_column]) ? params[:sort_column] : "lifetime_spend"
    @sort_direction = params[:sort_direction] == "asc" ? "asc" : "desc"

    # Materialise the creative set ONCE and derive metrics from these same
    # records. `ad_units` is written continuously by the hourly backfill
    # (BackfillAdCreativesJob -> MetaAdsService#sync_ad_units), so the
    # `AdUnit.attributable` predicate above is not stable across two separate
    # queries: a creative that gains its first attributable ad_unit between
    # query #1 and query #2 would appear in the second query but not the
    # first, leaving `sort_creatives` looking up a metrics hash key that was
    # never populated (nil) -> NoMethodError. Querying once removes the
    # window entirely.
    creatives = AdCreative
      .where(ad_account: accounts)
      .where(id: AdUnit.attributable.select(:ad_creative_id))
      .includes(:ad_account)
      .to_a

    @creative_metrics = AdCreative.batch_aggregated_metrics(creatives, @from_date..@to_date)
    @creatives = sort_creatives(creatives)
  end

  private

  # The account set the index renders: group view scope, narrowed by the
  # store switcher. Shared with #sync so both act on the same accounts.
  def scoped_ad_accounts
    view_scope = selected_view_group || current_company
    base = view_scope.respond_to?(:ad_accounts) ? view_scope.ad_accounts : visible_ad_accounts
    base = base.where(shopify_store: current_shopify_store) if current_shopify_store
    base.order(:account_name)
  end

  def find_selected_account(accounts)
    return nil if params[:ad_account_id].blank? || params[:ad_account_id] == "all"

    accounts.find_by(id: params[:ad_account_id])
  end

  def sync_target_accounts
    accounts = scoped_ad_accounts
    selected = find_selected_account(accounts)
    selected ? [ selected ] : accounts
  end

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
