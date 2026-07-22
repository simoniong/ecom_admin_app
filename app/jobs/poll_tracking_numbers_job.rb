class PollTrackingNumbersJob < ApplicationJob
  queue_as :default

  GIVE_UP_AFTER = 24.hours

  # Recurring (every 5 min): poll Raydo for deferred tracking numbers; give up
  # (failed) after GIVE_UP_AFTER. Per-package isolation so one failure can't
  # stall the batch.
  def perform
    Package.where(aasm_state: "applying_tracking", application_status: "pending")
           .where.not(raydo_order_id: [ nil, "" ]).find_each do |package|
      poll_one(package)
    rescue => e
      Rails.logger.error("[PollTracking] Package##{package.id}: #{e.class}: #{e.message}")
    end
  end

  private

  def poll_one(package)
    if package.applied_at.present? && package.applied_at < GIVE_UP_AFTER.ago
      package.update!(application_status: "failed", application_message: I18n.t("packages.apply.timeout"))
      return
    end

    PackageTrackingApplier.new(package).call # order_id present → applier polls
  end
end
