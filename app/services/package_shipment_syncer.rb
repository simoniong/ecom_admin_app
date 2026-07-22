# Orchestrates the 3 shipment side-effects for one shipped package, each step
# idempotent (skips when its completion marker is set). Carrier + 17Track are
# safe to repeat; Shopify create is serialized per order and reconciled inside
# ShopifyFulfillmentService. Any step failure → ship_sync_status "failed" with a
# safe message; the package stays shipped. Enqueued only when the store's
# shipping_sync_enabled is on (see PackageShipSyncJob / controller).
class PackageShipmentSyncer
  def initialize(package)
    @package = package
    @company = package.shopify_store.company
  end

  def call
    mark_carrier
    register_tracking
    push_shopify
    @package.update!(ship_sync_status: "succeeded", ship_sync_message: nil)
  rescue => e
    @package.update!(ship_sync_status: "failed", ship_sync_message: safe_message(e))
    false
  end

  private

  def mark_carrier
    return if @package.carrier_marked_at.present?

    account = @package.logistics_channel&.logistics_account
    raise "logistics not configured" if account.nil?

    FulfillmentService.for(account).mark_shipped(@package.package_code)
    @package.update!(carrier_marked_at: Time.current)
  end

  def register_tracking
    return if @package.tracking_registered_at.present?
    # 17Track needs company config; missing → skip (not a failure).
    return unless @company.tracking_enabled? && @company.tracking_api_key.present?

    # register raises only on a real API/transport error; an already-registered
    # number returns 200 (rejected dedupe) and does NOT raise → treat as success.
    TrackingService.new(api_key: @company.tracking_api_key).register([ @package.tracking_number ])
    @package.update!(tracking_registered_at: Time.current)
  end

  def push_shopify
    return if @package.shopify_fulfillment_id.present?

    # Serialize per order so sibling packages of a split order don't race the
    # same fulfillment orders / remainingQuantity.
    @package.order.with_lock do
      @package.reload
      return if @package.shopify_fulfillment_id.present?

      id = ShopifyFulfillmentService.new(@package).call
      @package.update!(shopify_fulfillment_id: id)
    end
  end

  def safe_message(error)
    error.message.to_s.truncate(1000)
  end
end
