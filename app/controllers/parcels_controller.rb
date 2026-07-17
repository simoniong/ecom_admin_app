class ParcelsController < AdminController
  # Viewing the report (index) is permission-based — see AdminController#authorize_page!,
  # gated on Membership::AVAILABLE_PERMISSIONS including "parcels". Every write
  # (update/destroy/import/preview/show_preview/confirm_import) is owner-only: a member
  # granted the "parcels" permission can look but must not be able to edit
  # money figures or delete rows.
  before_action :require_owner!, only: [ :import, :preview, :show_preview, :confirm_import, :update, :destroy ]

  SORTABLE = {
    "variance"  => "(orders.actual_shipping_cost - orders.estimated_shipping_cost)",
    # NULLIF guards the divide: an order with a NULL or zero estimate has no
    # meaningful overrun percentage, so the expression evaluates to NULL and
    # the "NULLS LAST" in the reorder pushes those rows to the end in both
    # directions rather than sorting them as if they were 0%.
    "variance_pct" => "(orders.actual_shipping_cost - orders.estimated_shipping_cost) / NULLIF(orders.estimated_shipping_cost, 0)",
    "ordered_at" => "orders.ordered_at",
    "actual"    => "orders.actual_shipping_cost",
    "estimated" => "orders.estimated_shipping_cost"
  }.freeze
  PER_PAGE = 25
  MAX_UPLOAD_BYTES = 20.megabytes

  # An order's DESTINATION country code, resolved from shopify_data exactly the
  # way ParcelsHelper#parcel_order_destination_address (and the service's zone
  # resolution) does: the shipping address's country_code when it is "present"
  # (Ruby's String#present? — non-blank after stripping whitespace), else the
  # billing address's. The TRIM/NULLIF mirrors #present? (so a whitespace-only
  # "   " shipping code falls through to billing just as it does on the row),
  # and the CASE returns the RAW code of the chosen address so the value equals
  # what the row displays. Used both to build the country-filter dropdown and
  # to filter by it, so the filter matches the country shown on each order row.
  # It's a frozen constant, never interpolated with user input — the filter
  # value is always passed as a bound parameter.
  DEST_COUNTRY_SQL =
    "CASE WHEN NULLIF(TRIM(orders.shopify_data #>> '{shipping_address,country_code}'), '') IS NOT NULL " \
    "THEN orders.shopify_data #>> '{shipping_address,country_code}' " \
    "ELSE orders.shopify_data #>> '{billing_address,country_code}' END"

  def index
    @tab = params[:tab] == "unmatched" ? "unmatched" : "orders"
    @page = [ params[:page].to_i, 1 ].max

    parse_dates

    if @tab == "unmatched"
      store_ids = visible_shopify_stores.pluck(:id)
      base = Parcel.unmatched.where(shopify_store_id: store_ids).order(shipped_at: :desc)
      @parcels = paginate(base)
      @assignable_orders = assignable_orders
      return
    end

    @sort_column    = SORTABLE.key?(params[:sort_column]) ? params[:sort_column] : "variance"
    @sort_direction = params[:sort_direction] == "asc" ? "asc" : "desc"
    # Repopulated verbatim, even when invalid, so the operator sees exactly
    # what they typed (and can correct it) rather than having it silently
    # vanish when it fails to parse.
    @min_over_pct = params[:min_over_pct]
    @country = params[:country].presence

    # Destination countries present in the current store + date window, for the
    # filter dropdown. Built from the date-scoped set only (not the other
    # filters) so the option list stays stable as the operator narrows by
    # country/overrun — picking a country must never make the other options
    # vanish. DISTINCT on the same resolved-country expression the filter uses.
    store_ids = visible_shopify_stores.pluck(:id)
    @countries = Order.where(shopify_store_id: store_ids)
                      .where.not(actual_shipping_cost: nil)
                      .ordered_between(@from_time, @to_time)
                      .distinct
                      .pluck(Arel.sql(DEST_COUNTRY_SQL))
                      .compact_blank
                      .sort

    @summary = shipping_variance_summary

    @orders = paginate(filtered_orders_base)
      .includes(:parcels, :shopify_store, order_line_items: :product_variant)
      .reorder(Arel.sql("#{SORTABLE.fetch(@sort_column)} #{@sort_direction} NULLS LAST"))

    # Per-parcel estimate comparison (basis + zone/variance decomposition) for
    # every order on the page. `@estimate_cache` is a single Hash shared by
    # every ParcelEstimateComparator call below — see
    # ShippingCostCalculator::basis's `cache:` param — so the rate-card-
    # version lookup and postal-zone resolution each run at most once per
    # distinct (company, country[, date/postal]) combination for the whole
    # page, not once per order. Without it this loop turns into O(orders)
    # rate-card lookups on a page that already renders up to 25 of them.
    # `.each_with_object` forces `@orders` to load (and cache) its records
    # once here; the view's later `@orders.each` reuses that same loaded set
    # rather than re-querying.
    @estimate_cache = {}
    @comparisons = @orders.each_with_object({}) do |order, memo|
      memo[order.id] = ParcelEstimateComparator.new(order, cache: @estimate_cache).call
    end
  end

  # Reconciliation export for the orders tab — one row per PARCEL (not per
  # order), so a multi-parcel order produces multiple rows. This is a read
  # (like index), not a write, so it's deliberately NOT behind require_owner!:
  # anyone who can see the report (owner or a member with the "parcels"
  # permission, per authorize_page!) can export it. It follows whatever
  # filter the caller passed (same query params as index) but is never
  # paginated — the whole filtered result goes into the file, since the
  # point is a complete reconciliation document, not a page's worth of it.
  def export
    parse_dates

    orders = filtered_orders_base
      .includes(:parcels, order_line_items: :product_variant)
      .order(ordered_at: :desc)

    # Shared across every ParcelEstimateComparator call below for the same
    # N+1-avoidance reason @estimate_cache exists on index — see the comment
    # there.
    estimate_cache = {}
    tz = ActiveSupport::TimeZone["Asia/Shanghai"]
    fmt = "%-d %b, %Y %H:%M"

    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "Parcels") do |sheet|
      header_style = sheet.styles.add_style(b: true, bg_color: "F2F2F2")

      sheet.add_row [
        t("parcels.export.order_name"),
        t("parcels.export.identifier"),
        t("parcels.export.internal_no"),
        t("parcels.export.tracking_number"),
        t("parcels.export.shipped_at"),
        t("parcels.export.country"),
        t("parcels.export.customer_zip"),
        t("parcels.export.estimated_zone"),
        t("parcels.export.billed_zone"),
        t("parcels.export.zone_match"),
        t("parcels.export.actual_weight_g"),
        t("parcels.export.billed_weight_g"),
        t("parcels.export.service_channel"),
        t("parcels.export.freight_cny"),
        t("parcels.export.registration_fee_cny"),
        t("parcels.export.tax_cny"),
        t("parcels.export.remote_area_fee_cny"),
        t("parcels.export.operation_fee_cny"),
        t("parcels.export.cost_cny"),
        t("parcels.export.estimate_cny"),
        t("parcels.export.variance_cny"),
        t("parcels.export.variance_pct")
      ], style: header_style

      # Axlsx auto-detects a plain numeric-looking String as a number cell
      # (e.g. a zip "2075" or a purely-numeric tracking/identifier value
      # would silently become the Integer 2075, and any leading zero in a
      # postal code would be lost the same way). Every non-money/non-weight
      # column here is an identifier or code, never a quantity to do
      # arithmetic on, so it's forced to :string; the money/weight columns
      # are left at nil (auto-detect numeric) since those genuinely are
      # numbers. `nil` forced-string values still write as a true blank
      # cell (verified: roo reads them back as nil, not "").
      column_types = [
        :string, :string, :string, :string, :string, # order_name..shipped_at
        :string, :string, :string, :string, :string,  # country..zone_match
        nil, nil,                                      # actual_weight_g, billed_weight_g
        :string,                                        # service_channel
        nil, nil, nil, nil, nil, nil,                   # freight_cny..cost_cny
        nil, nil, nil                                   # estimate_cny, variance_cny, variance_pct
      ]

      orders.each do |order|
        comparison = ParcelEstimateComparator.new(order, cache: estimate_cache).call
        zip = helpers.parcel_order_zip(order)
        estimated_zone = comparison.estimated_zone

        comparison.parcel_lines.each do |line|
          parcel = line.parcel

          sheet.add_row [
            order.name,
            parcel.identifier,
            parcel.internal_no,
            parcel.tracking_number,
            parcel.shipped_at&.in_time_zone(tz)&.strftime(fmt),
            parcel.country.presence || helpers.parcel_order_country_code(order),
            zip,
            estimated_zone,
            parcel.zone,
            zone_match_cell(estimated_zone, parcel.zone, line.zone_mismatch),
            parcel.actual_weight_g,
            parcel.billed_weight_g,
            parcel.service_channel,
            parcel.freight_cny,
            parcel.registration_fee_cny,
            parcel.tax_cny,
            parcel.remote_area_fee_cny,
            parcel.operation_fee_cny,
            parcel.cost_cny,
            line.estimate_cny,
            line.variance_cny,
            line.variance_pct
          ], types: column_types
        end
      end
    end

    filename = "parcels_reconciliation_#{Time.current.strftime('%Y%m%d_%H%M%S')}.xlsx"
    send_data package.to_stream.read,
              filename: filename,
              type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
              disposition: "attachment"
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

          # The orders-tab row now renders per-parcel estimate/variance/zone
          # figures alongside the raw billed numbers, so a post-edit replace
          # needs the same ParcelEstimateComparator line the index view uses
          # — otherwise the row would revert to showing no estimate at all
          # right after a save. Only one order's worth of work here (never a
          # loop), so no cache/N+1 concern like the index action has.
          if !@from_unmatched && @parcel.order
            comparison = ParcelEstimateComparator.new(@parcel.order).call
            @estimated_zone = comparison.estimated_zone
            @line = comparison.parcel_lines.find { |l| l.parcel.id == @parcel.id }
          end
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

  # The orders-tab filter set (date range / multi_parcel_only / over_only /
  # min_over_pct), extracted so index and export apply the EXACT same scope —
  # export exists to reconcile "what's on screen right now" with a carrier
  # bill, so it must never silently include or exclude an order the operator
  # can't also see on the page they filtered. Requires @from_time/@to_time
  # (parse_dates) to already be set. Unlike index, the caller decides whether
  # to paginate the result — export deliberately doesn't.
  def filtered_orders_base
    store_ids = visible_shopify_stores.pluck(:id)

    base = Order.where(shopify_store_id: store_ids)
                .where.not(actual_shipping_cost: nil)
                .ordered_between(@from_time, @to_time)

    base = base.name_matching(params[:q]) if params[:q].present?
    base = base.where(id: Parcel.group(:order_id).having("COUNT(*) > 1").select(:order_id)) if params[:multi_parcel_only].present?
    base = base.where("orders.actual_shipping_cost > orders.estimated_shipping_cost") if params[:over_only].present?
    base = base.where("#{DEST_COUNTRY_SQL} = ?", params[:country]) if params[:country].present?

    if (pct = parse_pct(params[:min_over_pct]))
      # estimated_shipping_cost can be NULL or 0 for orders that never got an
      # estimate. Those can't have a percentage computed against them at all —
      # dividing by zero or NULL, or reporting a meaningless "infinite" overrun —
      # so they're excluded outright rather than included under a nonsense value.
      base = base.where(
        "orders.estimated_shipping_cost > 0 AND " \
        "(orders.actual_shipping_cost - orders.estimated_shipping_cost) / orders.estimated_shipping_cost * 100 >= ?",
        pct
      )
    end

    base
  end

  # Totals across the WHOLE filtered set (not just the current page), so the
  # summary reflects everything the filter selected — the point is to compare,
  # e.g., total overrun per country as the operator switches the country filter.
  # Only orders that carry a frozen estimate count toward the totals (an order
  # with no estimate has no comparable variance). CNY is each order's
  # store-currency figure times that store's cost_fx_rate, so multi-store /
  # multi-fx sets still total correctly. Everything here is the frozen
  # estimated/actual_shipping_cost — the same basis the order rows, the sort and
  # the over/min-overrun filters use, so the summary can never disagree with the
  # rows it sits above.
  def shipping_variance_summary
    est_store, act_store, est_cny, act_cny =
      filtered_orders_base
        .where.not(estimated_shipping_cost: nil)
        .joins(:shopify_store)
        .pick(Arel.sql(
          "COALESCE(SUM(orders.estimated_shipping_cost), 0), " \
          "COALESCE(SUM(orders.actual_shipping_cost), 0), " \
          "COALESCE(SUM(orders.estimated_shipping_cost * shopify_stores.cost_fx_rate), 0), " \
          "COALESCE(SUM(orders.actual_shipping_cost * shopify_stores.cost_fx_rate), 0)"
        ))

    {
      estimated_store: est_store, actual_store: act_store,
      estimated_cny: est_cny, actual_cny: act_cny,
      variance_store: act_store - est_store,
      variance_cny: act_cny - est_cny,
      variance_pct: est_store.positive? ? ((act_store - est_store) / est_store * 100).round(2) : nil
    }
  end

  # Y/N only when both sides of the comparison actually exist — an unzoned
  # country (no estimated_zone) or a bill row missing its billed zone can't
  # be judged "matching" or "mismatched" at all, so the cell is left blank
  # (nil) rather than defaulting to either letter. When both are present,
  # this mirrors ParcelEstimateComparator::zone_mismatch exactly: mismatch
  # -> "N", otherwise -> "Y".
  def zone_match_cell(estimated_zone, billed_zone, zone_mismatch)
    return nil if estimated_zone.blank? || billed_zone.blank?

    zone_mismatch ? "N" : "Y"
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

  # Rejects blank, non-numeric and negative input by returning nil, so a
  # garbage value simply leaves the filter unapplied rather than 500ing the
  # page or being coerced into a nonsense threshold. Zero is a valid,
  # non-blank threshold ("≥0% overrun" = every overrun) and must not be
  # treated the same as blank.
  def parse_pct(value)
    return nil if value.blank?

    pct = BigDecimal(value.to_s, exception: false)
    return nil if pct.nil? || pct.negative?

    pct
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
      # Summed over final_rows, not rows: a duplicate identifier's earlier
      # occurrence(s) are overwritten by the last one and never land, so
      # counting every occurrence here would make this total describe rows
      # that will never be persisted — and disagree with total_converted
      # (already final_rows-based) at the approval screen the user reads
      # right before money is written.
      total_cny: final_rows.sum { |r| r[:cost_cny] || 0 },
      # Computed exactly the way confirm_import will persist it — round each
      # parcel's converted cost to 2dp, then sum — not Σcny ÷ fx. Across
      # hundreds of rows those two arithmetic orders drift apart, and this
      # total is the number the user approves before any money is written.
      total_converted: final_rows.sum { |r| ParcelUpserter.convert(r[:cost_cny], store.cost_fx_rate) },
      # Set only when ParcelBillParser had to derive cost_cny itself (the bill
      # had no 加单总运费（RMB) column) — the user is approving money on this
      # screen, and this component of it did not come from the bill.
      derived_operation_fee_count: final_rows.count { |r| r[:derived_operation_fee] }
    }
  end
end
