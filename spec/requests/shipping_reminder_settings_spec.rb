require "rails_helper"

RSpec.describe "ShippingReminderSettings", type: :request do
  let(:user) { create(:user) }
  let(:company) { user.companies.first }

  before { sign_in user }

  describe "PATCH /shipping_reminder_setting" do
    it "creates and saves email settings" do
      patch shipping_reminder_setting_path, params: {
        shipping_reminder_setting: {
          recipients_text: "a@b.com\nc@d.com",
          timezone: "UTC",
          send_hour: 10,
          frequency: "every_day"
        }
      }
      expect(response).to redirect_to(shipping_reminder_rules_path)
      setting = company.reload.shipping_reminder_setting
      expect(setting.recipients).to eq([ "a@b.com", "c@d.com" ])
      expect(setting.send_hour).to eq(10)
    end

    it "updates existing settings" do
      create(:shipping_reminder_setting, company: company, send_hour: 9)
      patch shipping_reminder_setting_path, params: {
        shipping_reminder_setting: {
          send_hour: 15,
          frequency: "every_week",
          send_day_of_week: 1
        }
      }
      expect(response).to redirect_to(shipping_reminder_rules_path)
      setting = company.shipping_reminder_setting.reload
      expect(setting.send_hour).to eq(15)
      expect(setting.frequency).to eq("every_week")
      expect(setting.send_day_of_week).to eq(1)
    end

    it "redirects with error for invalid email" do
      patch shipping_reminder_setting_path, params: {
        shipping_reminder_setting: {
          recipients_text: "not-valid",
          timezone: "UTC",
          send_hour: 9,
          frequency: "every_day"
        }
      }
      expect(response).to redirect_to(shipping_reminder_rules_path)
      follow_redirect!
      expect(response.body).to include("invalid email")
    end
  end

  describe "PATCH /shipping_reminder_setting/toggle" do
    it "turns on when off" do
      patch toggle_shipping_reminder_setting_path
      expect(response).to redirect_to(shipping_reminder_rules_path)
      setting = company.reload.shipping_reminder_setting
      expect(setting).to be_present
      expect(setting.enabled).to be true
    end

    it "turns off when on" do
      create(:shipping_reminder_setting, company: company, enabled: true)
      patch toggle_shipping_reminder_setting_path
      expect(response).to redirect_to(shipping_reminder_rules_path)
      expect(company.shipping_reminder_setting.reload.enabled).to be false
    end

    it "creates setting with defaults when none exists" do
      patch toggle_shipping_reminder_setting_path
      setting = company.reload.shipping_reminder_setting
      expect(setting.enabled).to be true
      expect(setting.timezone).to eq("UTC")
      expect(setting.send_hour).to eq(9)
      expect(setting.frequency).to eq("every_day")
    end
  end
end
