class ShippingReminderSettingsController < AdminController
  def update
    @setting = current_company.shipping_reminder_setting ||
               current_company.build_shipping_reminder_setting
    @setting.assign_attributes(setting_params)

    if @setting.save
      redirect_to shipping_reminder_rules_path, notice: t("shipping_reminders.settings_updated")
    else
      redirect_to shipping_reminder_rules_path, alert: @setting.errors.full_messages.join(", ")
    end
  end

  def toggle
    @setting = current_company.shipping_reminder_setting ||
               current_company.build_shipping_reminder_setting
    @setting.update!(enabled: !@setting.enabled?)
    redirect_to shipping_reminder_rules_path,
                notice: @setting.enabled? ? t("shipping_reminders.turned_on") : t("shipping_reminders.turned_off")
  end

  private

  def setting_params
    raw = params.require(:shipping_reminder_setting).permit(
      :enabled, :timezone, :send_hour, :frequency, :send_day_of_week, :recipients_text
    )
    if raw.key?(:recipients_text)
      raw[:recipients] = raw.delete(:recipients_text).to_s.split(/[\n,]+/).map(&:strip).compact_blank
    end
    raw
  end
end
