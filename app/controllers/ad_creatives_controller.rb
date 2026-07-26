class AdCreativesController < AdminController
  SORTABLE_COLUMNS = %w[
    three_sec_rate p50_rate p75_rate link_ctr cpc_link cpc_all cpm
    d1_spend d1_purchases d3_roas d5_roas
    lifetime_spend lifetime_roas
  ].freeze

  # Maps every anchor-gated SORTABLE_COLUMN (i.e. rendered through
  # _anchor_cell, driven by AdCreative#anchor_state) to the window length
  # anchor_state needs. A column absent from this hash is range-scoped and
  # never anchor-gated: three_sec_rate, p50_rate, p75_rate, link_ctr,
  # cpc_link, cpc_all, cpm. This is the single place that mapping lives --
  # #sort_creatives reads it rather than re-deriving it, so it cannot drift
  # from the windows index.html.erb's `render "anchor_cell"` calls use.
  ANCHOR_WINDOWS = {
    "d1_spend" => 1, "d1_purchases" => 1,
    "d3_roas" => 3, "d5_roas" => 5,
    "lifetime_spend" => nil, "lifetime_roas" => nil
  }.freeze

  BACKFILL_DAYS = 90

  PER_PAGE_DEFAULT = 50
  PER_PAGE_OPTIONS = [ 25, 50, 100, 200, 300, 500 ].freeze

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

    @page = [ params[:page].to_i, 1 ].max
    per_page = Integer(params[:per_page], exception: false)
    @per_page = PER_PAGE_OPTIONS.include?(per_page) ? per_page : PER_PAGE_DEFAULT

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

    # Sort BEFORE paginating, in Ruby, over the whole set: @sort_column is one
    # of SORTABLE_COLUMNS, every one a method on CreativeMetrics computed from
    # the aggregation queries above, not a real SQL column -- there is no
    # `ORDER BY` that could express it. Slicing the DB result first and then
    # sorting only that page would show an arbitrary page 1 (e.g. the highest
    # lifetime_spend creative could land on page 4), so the full set must be
    # sorted first and the page taken from the sorted array. @total_count
    # comes from this same in-memory array (not a fresh COUNT query) so the
    # single-SELECT-against-ad_creatives guarantee below still holds.
    sorted = sort_creatives(creatives)
    @total_count = sorted.size
    @total_pages = (@total_count.to_f / @per_page).ceil
    @page = [ @page, @total_pages ].min if @total_pages > 0
    @creatives = sorted.drop((@page - 1) * @per_page).first(@per_page)
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
    window = ANCHOR_WINDOWS[@sort_column]
    anchor_gated = ANCHOR_WINDOWS.key?(@sort_column)

    creatives.sort_by do |creative|
      metrics = @creative_metrics[creative.id]
      hidden = anchor_gated && anchor_value_hidden?(creative, window)
      # Hidden rows sort last regardless of direction: the leading 0/1 flag
      # dominates the tuple comparison, so `direction * value` (an invisible
      # number the user cannot see, per _anchor_cell) never gets a say for them.
      [ hidden ? 1 : 0, hidden ? 0 : direction * metrics.public_send(@sort_column).to_f, creative.name.to_s ]
    end
  end

  # Mirrors _anchor_cell's own rendering exactly: a value is hidden from the
  # user for every anchor_state except :ok, and -- since the lifetime columns
  # now show their number alongside the ⚠ marker -- also except :truncated
  # when window is nil (lifetime).
  def anchor_value_hidden?(creative, window)
    state = creative.anchor_state(window)
    return false if state == :ok
    return false if window.nil? && state == :truncated

    true
  end
end
