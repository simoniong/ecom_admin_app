class ShippingReminderMailer < ApplicationMailer
  helper :shipping_reminder

  def digest(company:, recipients:, alerts:, locale: "en")
    @company = company
    @alerts = alerts
    @rules = company.shipping_reminder_rules.index_by(&:rule_type)

    I18n.with_locale(locale) do
      mail(
        to: recipients,
        subject: t("shipping_reminders.email.subject", company: company.name)
      )
    end
  end
end
