class ShippingReminderCheckJob < ApplicationJob
  queue_as :default

  def perform
    ShippingReminderSetting.where(enabled: true).find_each do |setting|
      setting.with_lock do
        setting.reload
        next unless setting.time_to_send?

        company = setting.company
        next unless company.tracking_enabled?

        store_ids = company.shopify_stores.pluck(:id)
        next if store_ids.empty?

        rules = company.shipping_reminder_rules.enabled
        next if rules.empty?

        alerts = {}
        rules.each do |rule|
          next if rule.country_thresholds.blank?
          matches = rule.matching_fulfillments(store_ids)
          alerts[rule.rule_type] = matches if matches.any?
        end

        next if alerts.empty?

        setting.update!(last_sent_at: Time.current)

        ShippingReminderMailer.digest(
          company: company,
          recipients: setting.recipients,
          alerts: alerts,
          locale: company.locale
        ).deliver_later
      end
    end
  end
end
