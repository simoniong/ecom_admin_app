class ApplyTrackingJob < ApplicationJob
  queue_as :default

  # Single-apply and bulk fan-out both enqueue this per package.
  def perform(package_id)
    package = Package.find_by(id: package_id)
    return unless package&.applying_tracking?

    PackageTrackingApplier.new(package).call
  rescue => e
    Rails.logger.error("[ApplyTracking] Package##{package_id}: #{e.class}: #{e.message}")
  end
end
