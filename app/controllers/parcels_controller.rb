class ParcelsController < AdminController
  # Viewing the report (index) is permission-based — see AdminController#authorize_page!,
  # gated on Membership::AVAILABLE_PERMISSIONS including "parcels". Every write
  # (update/destroy/import/preview/show_preview/confirm_import) is owner-only: a member
  # granted the "parcels" permission can look but must not be able to edit
  # money figures or delete rows.
  before_action :require_owner!, only: [ :import, :preview, :show_preview, :confirm_import, :update, :destroy ]

  SORTABLE = {
    "variance"  => "(orders.actual_shipping_cost - orders.estimated_shipping_cost)",
    "ordered_at" => "orders.ordered_at",
    "actual"    => "orders.actual_shipping_cost",
    "estimated" => "orders.estimated_shipping_cost"
  }.freeze
  PER_PAGE = 25
  MAX_UPLOAD_BYTES = 20.megabytes

  def index
    @tab = params[:tab] == "unmatched" ? "unmatched" : "orders"
    @page = [ params[:page].to_i, 1 ].max
    store_ids = visible_shopify_stores.pluck(:id)

    parse_dates

    if @tab == "unmatched"
      base = Parcel.unmatched.where(shopify_store_id: store_ids).order(shipped_at: :desc)
      @parcels = paginate(base)
      @assignable_orders = assignable_orders
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

  # Parse + stage. Writes no Parcel rows — the parsed rows are staged in a
  # ParcelImportBatch row until the user confirms. Overwriting money silently
  # is exactly what this guards.
  #
  # Responds with a redirect, never a render: this is a non-GET form submission,
  # and Turbo Drive rejects any response to one that is not a redirect or a
  # turbo_stream ("Form responses must redirect to another location"). Rendering
  # the preview inline here left the browser sitting on the upload form with no
  # feedback at all. Post/Redirect/Get also makes the preview reloadable.
  def preview
    store = visible_shopify_stores.find_by(id: params[:shopify_store_id])
    return redirect_to(import_parcels_path, alert: t("parcels.import.store_required")) unless store
    return redirect_to(import_parcels_path, alert: t("parcels.import.fx_rate_missing", store: store.name)) unless store.cost_fx_rate&.positive?

    file = params[:file]
    return redirect_to(import_parcels_path, alert: t("parcels.import.file_required")) if file.blank? || !file.respond_to?(:tempfile)
    return redirect_to(import_parcels_path, alert: t("parcels.import.file_too_large")) if file.size > MAX_UPLOAD_BYTES

    result = ParcelBillParser.new(file.tempfile.path).call
    errors = result[:errors]
    rows = result[:rows]

    if rows.empty?
      return redirect_to(import_parcels_path, alert: t("parcels.import.no_rows", errors: errors.first(3).join("; ")))
    end

    # Drop this user's own unconfirmed batches for this store before staging
    # the new one, so re-uploads don't pile up abandoned pending rows.
    ParcelImportBatch.pending.where(shopify_store: store, user: current_user).destroy_all

    batch = ParcelImportBatch.create!(
      shopify_store: store,
      user: current_user,
      filename: file.original_filename,
      rows: rows,
      parse_errors: errors,
      row_count: rows.size,
      total_cny: rows.sum { |r| r[:cost_cny] || 0 }
    )

    redirect_to show_preview_parcels_path(batch_id: batch.id)
  end

  # Renders a staged batch for confirmation. Scoped to visible_shopify_stores
  # exactly as confirm_import is: without that, an owner could read another
  # company's in-flight bill — its parcel ids and money figures — by guessing
  # a batch id. A completed or absent batch must not render as if it were
  # still pending.
  def show_preview
    @batch = ParcelImportBatch.pending
                              .where(shopify_store_id: visible_shopify_stores.select(:id))
                              .find_by(id: params[:batch_id])
    return redirect_to(import_parcels_path, alert: t("parcels.import.expired")) if @batch.blank?

    @store = @batch.shopify_store
    @errors = @batch.parse_errors
    @summary = summarise(@store, @batch.staged_rows)

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
      batch.staged_rows.each do |row|
        ParcelUpserter.new(store: store, attrs: row).call
        count += 1
      end
      batch.update!(status: "completed", completed_at: Time.current)
    end

    redirect_to parcels_path, notice: t("parcels.import.done", count: count)
  rescue ParcelUpserter::MissingFxRate
    redirect_to import_parcels_path, alert: t("parcels.import.fx_rate_missing", store: store&.name)
  rescue ParcelUpserter::MissingCost, ParcelUpserter::MissingIdentifier
    redirect_to import_parcels_path, alert: t("parcels.import.cost_missing")
  rescue ActiveRecord::RangeError
    redirect_to import_parcels_path, alert: t("parcels.import.value_out_of_range")
  end

  def update
    parcel = scoped_parcels.find(params[:id])

    if parcel.update(recomputed_attrs(parcel))
      respond_to do |format|
        format.turbo_stream do
          @parcel = parcel.reload
          # The two tabs render a parcel with different markup (the unmatched
          # tab's row has 5 columns and an assign form; the orders tab's has 8
          # and a cost field), so the stream must know which one it is replying
          # to. A parcel that just got assigned leaves the unmatched tab
          # entirely and is removed rather than replaced.
          @from_unmatched = params[:tab] == "unmatched"
          @assignable_orders = assignable_orders if @from_unmatched
        end
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

  # The order list offered by the unmatched tab's assign dropdown. Shared by
  # index and by update, which has to re-render that same dropdown when an
  # assignment fails to take.
  # Not capped: with hundreds of named orders in a single month's bill, an
  # arbitrary limit silently drops valid assignment targets from the dropdown
  # with no error at all — the operator just can't find the order they need.
  def assignable_orders
    Order.where(shopify_store_id: visible_shopify_stores.select(:id))
         .where.not(name: nil)
         .order(ordered_at: :desc)
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
      fx  = parcel.fx_rate_snapshot.presence || parcel.shopify_store.cost_fx_rate
      cny = BigDecimal(attrs[:cost_cny].to_s, exception: false)
      # A non-numeric cost_cny (e.g. a pasted tracking number) must not 500 —
      # leave cost_amount untouched and let cost_cny's own presence/numericality
      # validation reject the write through the normal error branch. A blank
      # cost_cny is left alone the same way: with cost_amount now NOT NULL, a
      # parcel can't exist without a cost, so clearing the field is rejected
      # rather than silently keeping the old cost_amount under a blank ¥ cell.
      attrs[:cost_amount] = (cny / BigDecimal(fx.to_s)).round(2) if cny && fx&.positive?
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
    # A duplicate 订单编号 within the same file isn't two parcels — confirm_import
    # upserts by identifier, so the later row overwrites the earlier one and only
    # the LAST occurrence actually lands. Counting every occurrence as if it were
    # its own parcel is exactly how "will create 2, ¥216" turns into one ¥144
    # parcel after confirm. final_rows keeps one entry per identifier (the last
    # one, matching upsert order) so every count below matches what will exist
    # after confirm_import runs.
    final_rows = rows.reverse.uniq { |r| r[:identifier] }.reverse
    duplicate_identifiers = rows.map { |r| r[:identifier] }.tally.select { |_, n| n > 1 }.keys

    identifiers = final_rows.map { |r| r[:identifier] }
    existing = Parcel.where(shopify_store_id: store.id, identifier: identifiers).pluck(:identifier).to_set

    order_names = final_rows.map { |r| r[:order_name] }.compact.uniq
    known_names = Order.where(shopify_store_id: store.id, name: order_names).pluck(:name).to_set

    unmatched = final_rows.reject { |r| r[:order_name].present? && known_names.include?(r[:order_name]) }
    overwrite = final_rows.select { |r| existing.include?(r[:identifier]) }

    {
      total: rows.size,
      duplicate_count: duplicate_identifiers.size,
      duplicate_identifiers: duplicate_identifiers.first(20),
      overwrite_count: overwrite.size,
      create_count: final_rows.size - overwrite.size,
      unmatched_count: unmatched.size,
      unmatched_rows: unmatched.first(20),
      overwrite_rows: overwrite.first(20),
      total_cny: rows.sum { |r| r[:cost_cny] || 0 },
      # Computed exactly the way confirm_import will persist it — round each
      # parcel's converted cost to 2dp, then sum — not Σcny ÷ fx. Across
      # hundreds of rows those two arithmetic orders drift apart, and this
      # total is the number the user approves before any money is written.
      total_converted: final_rows.sum { |r| ParcelUpserter.convert(r[:cost_cny], store.cost_fx_rate) }
    }
  end
end
