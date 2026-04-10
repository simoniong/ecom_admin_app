class ShippingReminderMailer < ApplicationMailer
  def digest(company:, recipients:, alerts:, locale: "en")
    @company = company
    @alerts = alerts

    I18n.with_locale(locale) do
      mail(
        to: recipients,
        subject: t("shipping_reminders.email.subject", company: company.name)
      )
    end
  end
end
