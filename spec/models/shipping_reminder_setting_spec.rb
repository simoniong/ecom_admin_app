require "rails_helper"

RSpec.describe ShippingReminderSetting, type: :model do
  let(:company) { create(:company) }

  describe "validations" do
    it "is valid with valid attributes" do
      setting = build(:shipping_reminder_setting, company: company)
      expect(setting).to be_valid
    end

    it "validates timezone presence" do
      setting = build(:shipping_reminder_setting, company: company, timezone: nil)
      expect(setting).not_to be_valid
    end

    it "validates send_hour range" do
      setting = build(:shipping_reminder_setting, company: company, send_hour: 24)
      expect(setting).not_to be_valid
    end

    it "validates frequency inclusion" do
      setting = build(:shipping_reminder_setting, company: company, frequency: "monthly")
      expect(setting).not_to be_valid
    end

    it "validates company uniqueness" do
      create(:shipping_reminder_setting, company: company)
      duplicate = build(:shipping_reminder_setting, company: company)
      expect(duplicate).not_to be_valid
    end

    it "validates recipients email format" do
      setting = build(:shipping_reminder_setting, company: company, recipients: [ "not-an-email" ])
      expect(setting).not_to be_valid
      expect(setting.errors[:recipients]).to be_present
    end

    it "allows valid email addresses" do
      setting = build(:shipping_reminder_setting, company: company, recipients: [ "a@b.com", "test@example.org" ])
      expect(setting).to be_valid
    end

    it "requires send_day_of_week when weekly" do
      setting = build(:shipping_reminder_setting, company: company, frequency: "every_week", send_day_of_week: nil)
      expect(setting).not_to be_valid
      expect(setting.errors[:send_day_of_week]).to be_present
    end

    it "does not require send_day_of_week when daily" do
      setting = build(:shipping_reminder_setting, company: company, frequency: "every_day", send_day_of_week: nil)
      expect(setting).to be_valid
    end
  end

  describe "#time_to_send?" do
    it "returns false when disabled" do
      setting = build(:shipping_reminder_setting, company: company, enabled: false)
      expect(setting.time_to_send?).to be false
    end

    it "returns false when recipients empty" do
      setting = build(:shipping_reminder_setting, company: company, enabled: true, recipients: [])
      expect(setting.time_to_send?).to be false
    end

    it "returns true when current hour matches for daily" do
      now = Time.current.in_time_zone("UTC")
      setting = build(:shipping_reminder_setting, company: company,
                      enabled: true, timezone: "UTC", send_hour: now.hour,
                      frequency: "every_day", last_sent_at: nil)
      expect(setting.time_to_send?).to be true
    end

    it "returns false when current hour does not match" do
      now = Time.current.in_time_zone("UTC")
      different_hour = (now.hour + 1) % 24
      setting = build(:shipping_reminder_setting, company: company,
                      enabled: true, timezone: "UTC", send_hour: different_hour,
                      frequency: "every_day", last_sent_at: nil)
      expect(setting.time_to_send?).to be false
    end

    it "returns false when wrong day for weekly" do
      now = Time.current.in_time_zone("UTC")
      wrong_day = (now.wday + 1) % 7
      setting = build(:shipping_reminder_setting, company: company,
                      enabled: true, timezone: "UTC", send_hour: now.hour,
                      frequency: "every_week", send_day_of_week: wrong_day,
                      last_sent_at: nil)
      expect(setting.time_to_send?).to be false
    end

    it "returns true when correct day and hour for weekly" do
      now = Time.current.in_time_zone("UTC")
      setting = build(:shipping_reminder_setting, company: company,
                      enabled: true, timezone: "UTC", send_hour: now.hour,
                      frequency: "every_week", send_day_of_week: now.wday,
                      last_sent_at: nil)
      expect(setting.time_to_send?).to be true
    end

    it "returns false when already sent this hour (idempotency)" do
      now = Time.current.in_time_zone("UTC")
      setting = build(:shipping_reminder_setting, company: company,
                      enabled: true, timezone: "UTC", send_hour: now.hour,
                      frequency: "every_day", last_sent_at: Time.current)
      expect(setting.time_to_send?).to be false
    end
  end
end
