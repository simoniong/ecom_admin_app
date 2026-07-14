class ParcelsController < AdminController
  # Viewing the report (index) is permission-based — see AdminController#authorize_page!,
  # gated on Membership::AVAILABLE_PERMISSIONS including "parcels". Every write
  # (update/destroy/import/preview/confirm_import) is owner-only: a member
  # granted the "parcels" permission can look but must not be able to edit
  # money figures or delete rows.
  before_action :require_owner!, only: [ :import, :preview, :confirm_import, :update, :destroy ]

  SORTABLE = {
    "variance"  => "(orders.actual_shipping_cost - orders.estimated_shipping_cost)",
    "ordered_at" => "orders.ordered_at",
    "actual"    => "orders.actual_shipping_cost",
    "estimated" => "orders.estimated_shipping_cost"
  }.freeze
  PER_PAGE = 25

  def index
    @tab = params[:tab] == "unmatched" ? "unmatched" : "orders"
    @page = [ params[:page].to_i, 1 ].max
    store_ids = visible_shopify_stores.pluck(:id)

    parse_dates

    if @tab == "unmatched"
      base = Parcel.unmatched.where(shopify_store_id: store_ids).order(shipped_at: :desc)
      @parcels = paginate(base)
      @assignable_orders = Order.where(shopify_store_id: store_ids)
                                .where.not(name: nil)
                                .order(ordered_at: :desc)
                                .limit(200)
      return
    end

    @sort_column    = SORTABLE.key?(params[:sort_column]) ? params[:sort_column] : "variance"
    @sort_direction = params[:sort_direction] == "asc" ? "asc" : "desc"

    base = Order.where(shopify_store_id: store_ids)
                .where.not(actual_shipping_cost: nil)
                .ordered_between(@from_time, @to_time)

    base = base.where(id: Parcel.group(:order_id).having("COUNT(*) > 1").select(:order_id)) if params[:multi_parcel_only].present?
    base = base.where("orders.actual_shipping_cost > orders.estimated_shipping_cost") if params[:over_only].present?

    @orders = paginate(base)
      .includes(:parcels)
      .reorder(Arel.sql("#{SORTABLE.fetch(@sort_column)} #{@sort_direction} NULLS LAST"))
  end

  def import
    @stores = visible_shopify_stores.order(:name)
  end

  # Parse + summarise. Writes no Parcel rows — the parsed rows are staged in
  # a ParcelImportBatch row until the user confirms. Overwriting money
  # silently is exactly what this guards.
  def preview
    store = visible_shopify_stores.find_by(id: params[:shopify_store_id])
    return redirect_to(import_parcels_path, alert: t("parcels.import.store_required")) unless store
    return redirect_to(import_parcels_path, alert: t("parcels.import.fx_rate_missing", store: store.name)) unless store.cost_fx_rate&.positive?

    file = params[:file]
    return redirect_to(import_parcels_path, alert: t("parcels.import.file_required")) if file.blank?

    result = ParcelBillParser.new(file.tempfile.path).call
    @errors = result[:errors]
    rows = result[:rows]

    if rows.empty?
      return redirect_to(import_parcels_path, alert: t("parcels.import.no_rows", errors: @errors.first(3).join("; ")))
    end

    @store = store
    @summary = summarise(store, rows)

    # Drop this user's own unconfirmed batches for this store before staging
    # the new one, so re-uploads don't pile up abandoned pending rows.
    ParcelImportBatch.pending.where(shopify_store: store, user: current_user).destroy_all

    @batch = ParcelImportBatch.create!(
      shopify_store: store,
      user: current_user,
      filename: file.original_filename,
      rows: rows,
      row_count: rows.size,
      total_cny: @summary[:total_cny]
    )

    render :preview
  end

  def confirm_import
    batch = ParcelImportBatch.pending
                              .where(shopify_store_id: visible_shopify_stores.select(:id))
                              .find_by(id: params[:batch_id])
    return redirect_to(import_parcels_path, alert: t("parcels.import.expired")) if batch.blank?

    store = batch.shopify_store
    count = 0

    Parcel.transaction do
      batch.rows.each do |row|
        ParcelUpserter.new(store: store, attrs: row).call
        count += 1
      end
      batch.update!(status: "completed", completed_at: Time.current)
    end

    redirect_to parcels_path, notice: t("parcels.import.done", count: count)
  rescue ParcelUpserter::MissingFxRate
    redirect_to import_parcels_path, alert: t("parcels.import.fx_rate_missing", store: store&.name)
  rescue ParcelUpserter::MissingCost
    redirect_to import_parcels_path, alert: t("parcels.import.cost_missing")
  end

  def update
    parcel = scoped_parcels.find(params[:id])

    if parcel.update(recomputed_attrs(parcel))
      respond_to do |format|
        format.turbo_stream { @parcel = parcel.reload }
        format.html { redirect_to parcels_path, notice: t("parcels.updated") }
      end
    else
      redirect_to parcels_path, alert: parcel.errors.full_messages.join(", ")
    end
  end

  def destroy
    parcel = scoped_parcels.find(params[:id])
    parcel.destroy!
    redirect_to parcels_path(request.query_parameters.slice(:tab, :from_date, :to_date)),
                notice: t("parcels.destroyed")
  end

  private

  def require_owner!
    return if current_membership&.owner?

    redirect_to authenticated_root_path, alert: t("companies.no_permission")
  end

  def scoped_parcels
    Parcel.where(shopify_store_id: visible_shopify_stores.select(:id))
  end

  # Computes total_count/total_pages, clamps @page, and returns the
  # offset/limit-applied relation. Shared by both index tabs.
  def paginate(scope)
    @total_count = scope.count
    @total_pages = (@total_count.to_f / PER_PAGE).ceil
    @page = [ @page, @total_pages ].min if @total_pages.positive?
    scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end

  def parcel_params
    params.require(:parcel).permit(:cost_cny, :order_id)
  end

  # cost_amount is derived, never user-supplied: if the operator corrects the CNY
  # figure, the store-currency figure (and therefore the order rollup) must follow.
  def recomputed_attrs(parcel)
    attrs = parcel_params.to_h.symbolize_keys

    if attrs.key?(:order_id) && attrs[:order_id].present?
      # Never let a parcel be attached to an order in another company's store.
      attrs[:order_id] = Order.where(shopify_store_id: visible_shopify_stores.select(:id))
                              .where(id: attrs[:order_id]).pick(:id)
    end

    if attrs[:cost_cny].present?
      fx = parcel.fx_rate_snapshot.presence || parcel.shopify_store.cost_fx_rate
      attrs[:cost_amount] = (BigDecimal(attrs[:cost_cny].to_s) / BigDecimal(fx.to_s)).round(2) if fx&.positive?
    end

    attrs
  end

  def parse_dates
    tz = store_timezone
    today = Time.current.in_time_zone(tz).to_date
    @from_date = params[:from_date].present? ? Date.parse(params[:from_date]) : today - 30
    @to_date   = params[:to_date].present?   ? Date.parse(params[:to_date])   : today
    @from_time = tz.parse(@from_date.to_s).beginning_of_day.utc
    @to_time   = tz.parse(@to_date.to_s).end_of_day.utc
  rescue Date::Error
    @from_date = today - 30
    @to_date   = today
    @from_time = tz.parse(@from_date.to_s).beginning_of_day.utc
    @to_time   = tz.parse(@to_date.to_s).end_of_day.utc
  end

  def summarise(store, rows)
    identifiers = rows.map { |r| r[:identifier] }
    existing = Parcel.where(shopify_store_id: store.id, identifier: identifiers).pluck(:identifier).to_set

    order_names = rows.map { |r| r[:order_name] }.compact.uniq
    known_names = Order.where(shopify_store_id: store.id, name: order_names).pluck(:name).to_set

    unmatched = rows.reject { |r| r[:order_name].present? && known_names.include?(r[:order_name]) }
    overwrite = rows.select { |r| existing.include?(r[:identifier]) }

    {
      total: rows.size,
      overwrite_count: overwrite.size,
      create_count: rows.size - overwrite.size,
      unmatched_count: unmatched.size,
      unmatched_rows: unmatched.first(20),
      overwrite_rows: overwrite.first(20),
      total_cny: rows.sum { |r| r[:cost_cny] || 0 },
      total_converted: (rows.sum { |r| r[:cost_cny] || 0 } / store.cost_fx_rate).round(2)
    }
  end
end
