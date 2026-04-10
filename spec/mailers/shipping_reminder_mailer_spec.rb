require "rails_helper"

RSpec.describe ShippingReminderMailer, type: :mailer do
  let(:company) { create(:company, name: "Test Co") }
  let(:store) { create(:shopify_store, company: company) }
  let(:order) { create(:order, shopify_store: store) }
  let!(:rule) do
    create(:shipping_reminder_rule, company: company, rule_type: "not_delivered",
           country_thresholds: [ { "country" => "US", "days" => 14 } ])
  end
  let(:fulfillment) do
    create(:fulfillment, order: order, tracking_number: "TRACK123",
           destination_country: "US", shipped_at: 20.days.ago,
           tracking_status: "InTransit", latest_event_description: "In transit to destination")
  end

  describe "#digest in English" do
    let(:mail) do
      described_class.digest(
        company: company,
        recipients: [ "admin@example.com", "ops@example.com" ],
        alerts: { "not_delivered" => [ fulfillment ] },
        locale: "en"
      )
    end

    it "sends to all recipients" do
      expect(mail.to).to eq([ "admin@example.com", "ops@example.com" ])
    end

    it "includes company name in subject" do
      expect(mail.subject).to eq("Shipping Tracking Alert - Test Co")
    end

    it "includes rule type heading with configured days" do
      expect(mail.body.encoded).to include("Not delivered for over 14 days")
    end

    it "includes item count" do
      expect(mail.body.encoded).to include("1 item")
    end

    it "includes link to admin shipments page" do
      expect(mail.body.encoded).to include("View in admin panel")
      expect(mail.body.encoded).to include("/shipments")
    end

    it "includes fulfillment tracking number" do
      expect(mail.body.encoded).to include("TRACK123")
    end

    it "includes destination country" do
      expect(mail.body.encoded).to include("United States")
    end

    it "includes last event description" do
      expect(mail.body.encoded).to include("In transit to destination")
    end
  end

  describe "#digest in Chinese" do
    let(:mail) do
      described_class.digest(
        company: company,
        recipients: [ "admin@example.com" ],
        alerts: { "not_delivered" => [ fulfillment ] },
        locale: "zh-CN"
      )
    end

    it "uses Chinese subject" do
      expect(mail.subject).to include("物流追踪提醒")
    end

    it "uses Chinese column headers" do
      expect(mail.body.encoded).to include("运单号")
    end

    it "uses Chinese link text" do
      expect(mail.body.encoded).to include("在后台查看")
    end
  end
end
