require "rails_helper"

RSpec.describe ShippingReminderCheckJob, type: :job do
  let(:company) do
    create(:company,
           tracking_enabled: true,
           tracking_api_key: "A" * 32,
           tracking_mode: "new_only",
           tracking_starts_at: Time.current)
  end
  let(:store) { create(:shopify_store, company: company) }
  let(:order) { create(:order, shopify_store: store) }

  describe "#perform" do
    it "skips companies that have tracking disabled" do
      paused = create(:company)
      paused_store = create(:shopify_store, company: paused)
      paused_order = create(:order, shopify_store: paused_store)
      now = Time.current.in_time_zone("UTC")
      create(:shipping_reminder_setting, company: paused, enabled: true,
             timezone: "UTC", send_hour: now.hour, recipients: [ "test@example.com" ])
      create(:shipping_reminder_rule, company: paused, rule_type: "not_delivered",
             country_thresholds: [ { "country" => "US", "days" => 14 } ])
      create(:fulfillment, order: paused_order, tracking_number: "T1",
             destination_country: "US", shipped_at: 20.days.ago,
             tracking_status: "InTransit")

      expect { described_class.perform_now }.not_to have_enqueued_mail
    end

    it "does nothing when no settings are enabled" do
      create(:shipping_reminder_setting, company: company, enabled: false)
      expect { described_class.perform_now }.not_to have_enqueued_mail
    end

    it "does nothing when it is not time to send" do
      now = Time.current.in_time_zone("UTC")
      different_hour = (now.hour + 1) % 24
      create(:shipping_reminder_setting, company: company, enabled: true,
             timezone: "UTC", send_hour: different_hour)
      expect { described_class.perform_now }.not_to have_enqueued_mail
    end

    it "does nothing when company has no stores" do
      now = Time.current.in_time_zone("UTC")
      create(:shipping_reminder_setting, company: company, enabled: true,
             timezone: "UTC", send_hour: now.hour)
      create(:shipping_reminder_rule, company: company, rule_type: "not_delivered",
             country_thresholds: [ { "country" => "US", "days" => 14 } ])
      # No stores created for this company
      expect { described_class.perform_now }.not_to have_enqueued_mail
    end

    it "sends digest email when matching fulfillments exist" do
      now = Time.current.in_time_zone("UTC")
      setting = create(:shipping_reminder_setting, company: company, enabled: true,
                       timezone: "UTC", send_hour: now.hour, recipients: [ "test@example.com" ])
      create(:shipping_reminder_rule, company: company, rule_type: "not_delivered",
             country_thresholds: [ { "country" => "US", "days" => 14 } ])
      create(:fulfillment, order: order, tracking_number: "T1",
             destination_country: "US", shipped_at: 20.days.ago,
             tracking_status: "InTransit")

      expect { described_class.perform_now }
        .to have_enqueued_mail(ShippingReminderMailer, :digest)

      expect(setting.reload.last_sent_at).to be_present
    end

    it "skips when no fulfillments match" do
      now = Time.current.in_time_zone("UTC")
      create(:shipping_reminder_setting, company: company, enabled: true,
             timezone: "UTC", send_hour: now.hour, recipients: [ "test@example.com" ])
      create(:shipping_reminder_rule, company: company, rule_type: "not_delivered",
             country_thresholds: [ { "country" => "US", "days" => 14 } ])
      # Fulfillment is recent, won't match
      create(:fulfillment, order: order, tracking_number: "T1",
             destination_country: "US", shipped_at: 2.days.ago,
             tracking_status: "InTransit")

      expect { described_class.perform_now }.not_to have_enqueued_mail
    end
  end
end
