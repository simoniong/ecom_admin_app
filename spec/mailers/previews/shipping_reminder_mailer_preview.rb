class ShippingReminderMailerPreview < ActionMailer::Preview
  # Preview at:
  #   /rails/mailers/shipping_reminder_mailer/digest          (English)
  #   /rails/mailers/shipping_reminder_mailer/digest_zh_cn    (简体中文)
  #   /rails/mailers/shipping_reminder_mailer/digest_zh_tw    (繁體中文)

  def digest
    build_digest("en")
  end

  def digest_zh_cn
    build_digest("zh-CN")
  end

  def digest_zh_tw
    build_digest("zh-TW")
  end

  private

  def build_digest(locale)
    company = Company.first
    fulfillments = Fulfillment.joins(:order)
                              .where(orders: { shopify_store_id: company.shopify_stores.pluck(:id) })
                              .with_tracking
                              .limit(10)

    alerts = {}

    not_delivered = fulfillments.where.not(tracking_status: "Delivered").where.not(shipped_at: nil).limit(3).to_a
    alerts["not_delivered"] = not_delivered if not_delivered.any?

    stale = fulfillments.where.not(last_event_at: nil).where(last_event_at: ...3.days.ago).limit(3).to_a
    alerts["without_updates"] = stale if stale.any?

    stopped = fulfillments.where(tracking_status: %w[Exception Expired]).limit(2).to_a
    alerts["tracking_stopped"] = stopped if stopped.any?

    alerts["not_delivered"] = fulfillments.limit(3).to_a if alerts.empty?

    ShippingReminderMailer.digest(
      company: company,
      recipients: [ "preview@example.com" ],
      alerts: alerts,
      locale: locale
    )
  end
end
