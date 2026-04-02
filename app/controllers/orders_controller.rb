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

    orders = Order.includes(:customer, :fulfillments).by_recency
    orders = orders.ordered_between(@from_date, @to_date)
    orders = orders.search_by(@search) if @search
    orders = orders.by_financial_status(@financial_status) if @financial_status
    orders = orders.by_fulfillment_status(@fulfillment_status) if @fulfillment_status

    @total_count = orders.count
    @total_pages = (@total_count.to_f / PER_PAGE).ceil
    @page = [ @page, @total_pages ].min if @total_pages > 0

    @orders = orders
      .reorder(@sort_column => @sort_direction)
      .offset((@page - 1) * PER_PAGE)
      .limit(PER_PAGE)

    @summary = {
      count: @total_count,
      total_revenue: orders.sum(:total_price)
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
    @from_date = params[:from_date].present? ? Date.parse(params[:from_date]) : 30.days.ago.to_date
    @to_date = params[:to_date].present? ? Date.parse(params[:to_date]) : Date.current
  rescue Date::Error
    @from_date = 30.days.ago.to_date
    @to_date = Date.current
  end
end
