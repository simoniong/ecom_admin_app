class PackageShipSyncJob < ApplicationJob
  queue_as :default

  def perform(package_id)
    package = Package.find_by(id: package_id)
    return unless package&.shipped?

    PackageShipmentSyncer.new(package).call
  rescue => e
    Rails.logger.error("[ShipSync] Package##{package_id}: #{e.class}: #{e.message}")
  end
end
