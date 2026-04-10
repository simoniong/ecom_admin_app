class ShipmentsController < AdminController
  PER_PAGE = 25
  SORTABLE_COLUMNS = %w[created_at last_event_at shipped_at transit_days].freeze
  SORT_COLUMN_MAP = {
    "input_time" => "fulfillments.created_at",
    "order_time" => "orders.ordered_at",
    "latest_event_update_time" => "fulfillments.last_event_at",
    "shipping_time" => "fulfillments.shipped_at",
    "transit_time" => "fulfillments.transit_days"
  }.freeze

  def index
    build_base_scope
    apply_filters
    compute_status_counts
    apply_status_filter
    apply_sorting
    paginate
    load_filter_options
  end

  def show
    store_ids = current_company.shopify_stores.pluck(:id)
    @fulfillment = Fulfillment.with_tracking
      .joins(:order)
      .where(orders: { shopify_store_id: store_ids })
      .includes(order: [ :customer, :shopify_store ])
      .find(params[:id])

    @order = @fulfillment.order
    @customer = @order.customer
    @store = @order.shopify_store
    @events = @fulfillment.tracking_events
    @line_items = @fulfillment.shopify_data&.dig("line_items") || @order.shopify_data&.dig("line_items") || []
    @shipping_address = @order.shopify_data&.dig("shipping_address") || {}
    @shipping_lines = @order.shopify_data&.dig("shipping_lines") || []
    @tracking_url = safe_tracking_url(@fulfillment.tracking_url)
    @tz = ActiveSupport::TimeZone["Asia/Shanghai"]
  end

  def archive
    fulfillment = find_fulfillment
    fulfillment.update!(archived_at: Time.current)
    redirect_to shipment_path(id: fulfillment.id), notice: t("shipments.show.archived_notice")
  end

  def unarchive
    fulfillment = find_fulfillment
    fulfillment.update!(archived_at: nil)
    redirect_to shipment_path(id: fulfillment.id), notice: t("shipments.show.unarchived_notice")
  end

  def bulk_archive
    ids = sanitize_ids(params[:ids])
    count = scoped_fulfillments(ids).where(archived_at: nil).update_all(archived_at: Time.current)
    redirect_to shipments_path(archived: params[:archived]), notice: t("shipments.bulk.archived_notice", count: count)
  end

  def bulk_unarchive
    ids = sanitize_ids(params[:ids])
    count = scoped_fulfillments(ids).where.not(archived_at: nil).update_all(archived_at: nil)
    redirect_to shipments_path(archived: params[:archived]), notice: t("shipments.bulk.unarchived_notice", count: count)
  end

  def bulk_add_tags
    ids = sanitize_ids(params[:ids])
    tags = Array(params[:tags]).map(&:strip).reject(&:blank?).uniq
    return redirect_to shipments_path(archived: params[:archived]) if tags.empty?

    Fulfillment.transaction do
      scoped_fulfillments(ids).find_each do |f|
        f.update!(tags: (f.tags | tags))
      end
    end
    redirect_to shipments_path(archived: params[:archived]), notice: t("shipments.tags.added_notice")
  end

  def bulk_remove_tags
    ids = sanitize_ids(params[:ids])
    tags = Array(params[:tags]).map(&:strip).reject(&:blank?)
    return redirect_to shipments_path(archived: params[:archived]) if tags.empty?

    Fulfillment.transaction do
      scoped_fulfillments(ids).find_each do |f|
        f.update!(tags: (f.tags - tags))
      end
    end
    redirect_to shipments_path(archived: params[:archived]), notice: t("shipments.tags.removed_notice")
  end

  def available_tags
    store_ids = current_company.shopify_stores.pluck(:id)
    subquery = Fulfillment.with_tracking
      .joins(:order)
      .where(orders: { shopify_store_id: store_ids })
      .where("tags IS NOT NULL AND tags != '{}'::varchar[]")
      .select(:tags).to_sql
    tags = Fulfillment.connection.select_values(
      "SELECT DISTINCT unnest(tags) AS tag FROM (#{subquery}) AS t ORDER BY tag"
    )

    render json: tags
  end

  def add_tags
    fulfillment = find_fulfillment
    tags = Array(params[:tags]).map(&:strip).reject(&:blank?).uniq
    fulfillment.update!(tags: (fulfillment.tags | tags)) if tags.any?
    redirect_to shipment_path(id: fulfillment.id), notice: t("shipments.tags.added_notice")
  end

  def remove_tag
    fulfillment = find_fulfillment
    tag = params[:tag].to_s.strip
    fulfillment.update!(tags: fulfillment.tags - [ tag ]) if tag.present?
    redirect_to shipment_path(id: fulfillment.id), notice: t("shipments.tags.removed_notice")
  end

  def sync
    current_company.shopify_stores.find_each do |store|
      SyncAllShopifyOrdersJob.perform_later(store.id)
    end

    redirect_to shipments_path, notice: t("shipments.sync_enqueued")
  end

  private

  def safe_tracking_url(url)
    return nil if url.blank?

    uri = URI.parse(url)
    uri.is_a?(URI::HTTP) ? url : nil
  rescue URI::InvalidURIError
    nil
  end

  def sanitize_ids(ids)
    uuid_regex = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
    Array(ids).select { |id| id.match?(uuid_regex) }
  end

  def find_fulfillment
    store_ids = current_company.shopify_stores.pluck(:id)
    Fulfillment.joins(:order).where(orders: { shopify_store_id: store_ids }).find(params[:id])
  end

  def scoped_fulfillments(ids)
    store_ids = current_company.shopify_stores.pluck(:id)
    Fulfillment.where(id: ids).joins(:order).where(orders: { shopify_store_id: store_ids })
  end

  def build_base_scope
    @archived = params[:archived] == "true"
    @base_scope = Fulfillment.with_tracking.joins(order: :customer)
    @base_scope = @archived ? @base_scope.archived : @base_scope.active

    if current_shopify_store
      @base_scope = @base_scope.by_store(current_shopify_store.id)
    else
      store_ids = current_company.shopify_stores.pluck(:id)
      @base_scope = @base_scope.joins(:order).where(orders: { shopify_store_id: store_ids })
    end
  end

  def apply_filters
    @search = params[:search].presence
    @status_tab = params[:status_tab].presence
    @status_filter = params[:status].presence
    @sub_status_filter = params[:sub_status].presence
    @destination = params[:destination].presence
    @origin_carrier_filter = params[:origin_carrier].presence
    @destination_carrier_filter = params[:destination_carrier].presence
    @store_filter = params[:store_id].presence
    @event_from = params[:event_from].presence
    @event_to = params[:event_to].presence
    @shipped_from = params[:shipped_from].presence
    @shipped_to = params[:shipped_to].presence
    @transit_min = params[:transit_min].presence
    @transit_max = params[:transit_max].presence
    @tag_filters = Array(params[:tags]).reject(&:blank?)

    @filtered_scope = @base_scope
    @filtered_scope = @filtered_scope.search_by(@search) if @search
    @filtered_scope = @filtered_scope.by_destination(@destination) if @destination
    @filtered_scope = @filtered_scope.by_origin_carrier(@origin_carrier_filter) if @origin_carrier_filter
    @filtered_scope = @filtered_scope.by_destination_carrier(@destination_carrier_filter) if @destination_carrier_filter
    @filtered_scope = @filtered_scope.where(tracking_sub_status: @sub_status_filter) if @sub_status_filter
    if @event_from && (date = Date.iso8601(@event_from) rescue nil)
      @filtered_scope = @filtered_scope.where(last_event_at: date.beginning_of_day..)
    end
    if @event_to && (date = Date.iso8601(@event_to) rescue nil)
      @filtered_scope = @filtered_scope.where(last_event_at: ..date.end_of_day)
    end
    if @shipped_from && (date = Date.iso8601(@shipped_from) rescue nil)
      @filtered_scope = @filtered_scope.where(shipped_at: date.beginning_of_day..)
    end
    if @shipped_to && (date = Date.iso8601(@shipped_to) rescue nil)
      @filtered_scope = @filtered_scope.where(shipped_at: ..date.end_of_day)
    end
    if @transit_min && (val = Integer(@transit_min, exception: false)) && val >= 0
      @filtered_scope = @filtered_scope.where(transit_days: val..)
    end
    if @transit_max && (val = Integer(@transit_max, exception: false)) && val >= 0
      @filtered_scope = @filtered_scope.where(transit_days: ..val)
    end

    if @store_filter
      @filtered_scope = @filtered_scope.joins(:order).where(orders: { shopify_store_id: @store_filter })
    end
    if @tag_filters.any?
      @filtered_scope = @filtered_scope.where("fulfillments.tags && ARRAY[?]::varchar[]", @tag_filters)
    end
  end

  def compute_status_counts
    counts = @filtered_scope.group(:tracking_status).count
    @status_counts = {}
    Fulfillment::TRACKING_STATUSES.each { |s| @status_counts[s] = counts[s] || 0 }
    @status_counts["All"] = counts.values.sum
  end

  def apply_status_filter
    @shipments_scope = @filtered_scope

    if @status_tab.present? && @status_tab != "All"
      @shipments_scope = @shipments_scope.by_tracking_status(@status_tab)
    end

    if @status_filter.present?
      @shipments_scope = @shipments_scope.by_tracking_status(@status_filter)
    end
  end

  def apply_sorting
    @sort_field = SORT_COLUMN_MAP.key?(params[:sort_field]) ? params[:sort_field] : "input_time"
    @sort_direction = params[:sort_direction] == "asc" ? "asc" : "desc"
    sort_column = SORT_COLUMN_MAP[@sort_field]

    @shipments_scope = @shipments_scope.reorder(Arel.sql("#{sort_column} #{@sort_direction}"))
  end

  def paginate
    @page = [ params[:page].to_i, 1 ].max
    @total_count = @shipments_scope.count
    @total_pages = (@total_count.to_f / PER_PAGE).ceil
    @page = [ @page, [ @total_pages, 1 ].max ].min

    @shipments = @shipments_scope
      .includes(order: [ :customer, :shopify_store ])
      .offset((@page - 1) * PER_PAGE)
      .limit(PER_PAGE)
  end

  def load_filter_options
    @destinations = @base_scope.where.not(destination_country: [ nil, "" ]).distinct.pluck(:destination_country).sort
    @origin_carriers = @base_scope.where.not(origin_carrier: [ nil, "" ]).distinct.pluck(:origin_carrier).sort
    @destination_carriers = @base_scope.where.not(destination_carrier: [ nil, "" ]).distinct.pluck(:destination_carrier).sort
    @stores = current_company.shopify_stores
    subquery = @base_scope.where("tags IS NOT NULL AND tags != '{}'::varchar[]").select(:tags).to_sql
    @available_tags = Fulfillment.connection.select_values(
      "SELECT DISTINCT unnest(tags) AS tag FROM (#{subquery}) AS t ORDER BY tag"
    )
  end
end
