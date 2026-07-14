# The single write path for parcels. Both the Excel importer and the agent API
# call this, so a parcel created by an AI agent obeys exactly the same rules as
# one imported from a spreadsheet.
class ParcelUpserter
  class MissingFxRate < StandardError; end

  ATTRIBUTES = %i[
    internal_no tracking_number shipped_at service_channel zone country
    actual_weight_g billed_weight_g
    cost_cny freight_cny registration_fee_cny tax_cny remote_area_fee_cny operation_fee_cny
  ].freeze

  def initialize(store:, attrs:)
    @store = store
    @attrs = attrs.symbolize_keys
  end

  def call
    fx = @store.cost_fx_rate
    raise MissingFxRate, "store #{@store.id} has no cost_fx_rate" unless fx&.positive?

    parcel = Parcel.find_or_initialize_by(
      shopify_store_id: @store.id,
      identifier: @attrs.fetch(:identifier)
    )

    parcel.assign_attributes(@attrs.slice(*ATTRIBUTES))
    parcel.order_id         = resolve_order_id
    parcel.fx_rate_snapshot = fx
    parcel.cost_amount      = converted_cost(fx)
    parcel.save!
    parcel
  end

  private

  # Bill "交易编号" (e.g. PKS#3037) is the Shopify order name verbatim — no
  # string munging needed. Scoped to the store so two stores can't cross-match.
  def resolve_order_id
    name = @attrs[:order_name]
    return nil if name.blank?

    Order.where(shopify_store_id: @store.id, name: name.to_s.strip).pick(:id)
  end

  def converted_cost(fx)
    cny = @attrs[:cost_cny]
    return nil if cny.blank?

    (BigDecimal(cny.to_s) / BigDecimal(fx.to_s)).round(2)
  end
end
