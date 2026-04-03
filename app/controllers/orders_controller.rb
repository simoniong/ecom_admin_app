class OrdersController < AdminController
  SORTABLE_COLUMNS = %w[ordered_at total_price financial_status fulfillment_status].freeze
  PER_PAGE = 25

  def index
    @search = params[:search].presence
    @financial_status = params[:financial_status].presence
    @fulfillment_status = params[:fulfillment_status].presence
    @sort_column = SORTABLE_COLUMNS.include?(params[:sort_column]) ? params[:sort_column] : "ordered_at"
    @sort_direction = params[:sort_direction] == "asc" ? "asc" : "desc"
    @page = [ params[:page].to_i, 1 ].max

    parse_dates

    if current_shopify_store
      base_orders = current_shopify_store.orders.by_recency
    else
      store_ids = current_user.shopify_stores.pluck(:id)
      base_orders = Order.where(shopify_store_id: store_ids).by_recency
    end
    base_orders = base_orders.ordered_between(@from_time, @to_time)
    base_orders = base_orders.search_by(@search) if @search
    base_orders = base_orders.by_financial_status(@financial_status) if @financial_status
    base_orders = base_orders.by_fulfillment_status(@fulfillment_status) if @fulfillment_status

    @total_count = base_orders.count
    @total_pages = (@total_count.to_f / PER_PAGE).ceil
    @page = [ @page, @total_pages ].min if @total_pages > 0

    @orders = base_orders
      .includes(:customer, :fulfillments)
      .reorder(@sort_column => @sort_direction)
      .offset((@page - 1) * PER_PAGE)
      .limit(PER_PAGE)

    @summary = {
      count: @total_count,
      total_revenue: base_orders.sum(:total_price)
    }
  end

  def sync
    current_user.shopify_stores.find_each do |store|
      SyncAllShopifyOrdersJob.perform_later(store.id)
    end

    redirect_to orders_path, notice: t("orders.sync_enqueued")
  end

  private

  def parse_dates
    tz = store_timezone
    today = Time.current.in_time_zone(tz).to_date
    @from_date = params[:from_date].present? ? Date.parse(params[:from_date]) : today - 30
    @to_date = params[:to_date].present? ? Date.parse(params[:to_date]) : today
    @from_time = tz.parse(@from_date.to_s).beginning_of_day.utc
    @to_time = tz.parse(@to_date.to_s).end_of_day.utc
  rescue Date::Error
    @from_date = today - 30
    @to_date = today
    @from_time = tz.parse(@from_date.to_s).beginning_of_day.utc
    @to_time = tz.parse(@to_date.to_s).end_of_day.utc
  end
end
