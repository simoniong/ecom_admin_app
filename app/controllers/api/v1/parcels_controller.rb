class Api::V1::ParcelsController < Api::CompanyBaseController
  def index
    parcels = company_parcels.includes(:order)
    parcels = parcels.unmatched if params[:unmatched].to_s == "true"

    if params[:order_name].present?
      order_ids = Order.where(shopify_store_id: company_stores.select(:id), name: params[:order_name]).select(:id)
      parcels = parcels.where(order_id: order_ids)
    end

    if params[:from].present? && params[:to].present?
      parcels = parcels.where(shipped_at: Time.zone.parse(params[:from])..Time.zone.parse(params[:to]))
    end

    render json: parcels.order(shipped_at: :desc).limit(500).map { |p| parcel_json(p) }
  end

  def show
    render json: parcel_json(find_parcel!)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Parcel not found" }, status: :not_found
  end

  def create
    store = company_stores.find_by(id: params[:shopify_store_id])
    return render(json: { error: "Store not found" }, status: :not_found) unless store

    parcel = ParcelUpserter.new(store: store, attrs: upsert_params).call
    render json: parcel_json(parcel), status: :created
  rescue ParcelUpserter::MissingFxRate
    render json: { error: "Store has no cost_fx_rate configured" }, status: :unprocessable_entity
  rescue ParcelUpserter::MissingCost
    render json: { error: "cost_cny is required" }, status: :unprocessable_entity
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Validation failed", details: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def update
    parcel = find_parcel!
    attrs = upsert_params.merge(identifier: parcel.identifier)
    attrs[:order_name] = parcel.order&.name unless params.key?(:order_name)

    updated = ParcelUpserter.new(store: parcel.shopify_store, attrs: attrs).call
    render json: parcel_json(updated)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Parcel not found" }, status: :not_found
  rescue ParcelUpserter::MissingFxRate
    render json: { error: "Store has no cost_fx_rate configured" }, status: :unprocessable_entity
  rescue ParcelUpserter::MissingCost
    render json: { error: "cost_cny is required" }, status: :unprocessable_entity
  end

  private

  def find_parcel!
    company_parcels.find_by!(identifier: params[:identifier])
  end

  UPSERT_KEYS = %i[
    identifier order_name internal_no tracking_number shipped_at service_channel
    zone country actual_weight_g billed_weight_g
    cost_cny freight_cny registration_fee_cny tax_cny remote_area_fee_cny operation_fee_cny
  ].freeze

  def upsert_params
    params.permit(*UPSERT_KEYS).to_h.symbolize_keys
  end

  def parcel_json(parcel)
    {
      id: parcel.id,
      identifier: parcel.identifier,
      internal_no: parcel.internal_no,
      tracking_number: parcel.tracking_number,
      order_name: parcel.order&.name,
      matched: parcel.order_id.present?,
      shipped_at: parcel.shipped_at,
      service_channel: parcel.service_channel,
      zone: parcel.zone,
      country: parcel.country,
      actual_weight_g: parcel.actual_weight_g,
      billed_weight_g: parcel.billed_weight_g,
      cost_cny: parcel.cost_cny,
      freight_cny: parcel.freight_cny,
      registration_fee_cny: parcel.registration_fee_cny,
      tax_cny: parcel.tax_cny,
      remote_area_fee_cny: parcel.remote_area_fee_cny,
      operation_fee_cny: parcel.operation_fee_cny,
      fx_rate_snapshot: parcel.fx_rate_snapshot,
      cost_amount: parcel.cost_amount
    }
  end
end
