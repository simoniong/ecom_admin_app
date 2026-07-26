# Applies (or polls) a Raydo tracking number for one package already in
# applying_tracking. On an immediate/deferred/failed create, or a poll of an
# existing order, it updates the package's application_* fields and moves it to
# pending_label on success. Create errors mark failed; poll errors are transient
# (left pending — PollTrackingNumbersJob's 24h cap decides the give-up).
# See docs/superpowers/specs/2026-07-22-order-packing-phase2c-apply-tracking-design.md.
class PackageTrackingApplier
  def initialize(package)
    @package = package
  end

  def call
    channel = @package.logistics_channel
    account = channel&.logistics_account
    return fail!("logistics not configured") if account.nil? || channel.product_id.blank?

    raydo = FulfillmentService.for(account)
    @package.raydo_order_id.present? ? poll(raydo) : create(raydo)
  end

  private

  def create(raydo)
    result = raydo.create_order(@package)
    return fail!(result.message || "order creation failed") unless result.success?

    if result.deferred?
      @package.update!(raydo_order_id: result.order_id, applied_at: Time.current,
                       application_status: "pending", application_message: nil)
    else
      @package.update!(raydo_order_id: result.order_id, tracking_number: result.tracking_number,
                       applied_at: Time.current, application_status: "succeeded", application_message: nil)
      @package.to_label!
    end
  rescue FulfillmentService::Error => e
    fail!(e.message)
  end

  def poll(raydo)
    result = raydo.get_tracking_number(@package.raydo_order_id)
    return unless result.ready? # not out yet — leave pending for the next poll cycle

    @package.update!(tracking_number: result.tracking_number, carrier: result.carrier,
                     application_status: "succeeded", application_message: nil)
    @package.to_label!
  rescue FulfillmentService::Error => e
    # Transient poll failure — do NOT flip to failed; the recurring poller
    # retries, and the 24h cap (PollTrackingNumbersJob) is the give-up.
    Rails.logger.warn("[TrackingApplier] poll Package##{@package.id}: #{e.message}")
  end

  def fail!(message)
    @package.update!(application_status: "failed", application_message: message.to_s.truncate(1000))
    false
  end
end
