class ParcelsController < AdminController
  # Only :import/:preview/:confirm_import exist so far — :index/:update/:destroy
  # land in a later task. Listing not-yet-defined actions here would trip
  # config.action_controller.raise_on_missing_callback_actions (test.rb) with
  # AbstractController::ActionNotFound on every request. Task 5 must add
  # :update and :destroy to this list when it defines those actions.
  before_action :require_owner!, only: [ :import, :preview, :confirm_import ]

  CACHE_TTL = 30.minutes

  def import
    @stores = visible_shopify_stores.order(:name)
  end

  # Parse + summarise. Writes nothing — the rows are held in Solid Cache until
  # the user confirms. Overwriting money silently is exactly what this guards.
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

    token = SecureRandom.hex(16)
    Rails.cache.write(cache_key(token), { store_id: store.id, rows: rows }, expires_in: CACHE_TTL)
    session[:parcel_import_token] = token
    @token = token

    render :preview
  end

  def confirm_import
    payload = Rails.cache.read(cache_key(params[:token]))
    return redirect_to(import_parcels_path, alert: t("parcels.import.expired")) if payload.blank?

    store = visible_shopify_stores.find_by(id: payload[:store_id])
    return redirect_to(import_parcels_path, alert: t("parcels.import.store_required")) unless store

    count = 0
    Parcel.transaction do
      payload[:rows].each do |row|
        ParcelUpserter.new(store: store, attrs: row).call
        count += 1
      end
    end

    Rails.cache.delete(cache_key(params[:token]))
    session.delete(:parcel_import_token)

    redirect_to parcels_path, notice: t("parcels.import.done", count: count)
  rescue ParcelUpserter::MissingFxRate
    redirect_to import_parcels_path, alert: t("parcels.import.fx_rate_missing", store: store&.name)
  rescue ParcelUpserter::MissingCost
    redirect_to import_parcels_path, alert: t("parcels.import.cost_missing")
  end

  private

  def require_owner!
    return if current_membership&.owner?

    redirect_to authenticated_root_path, alert: t("companies.no_permission")
  end

  def cache_key(token)
    "parcel_import:#{token}"
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
