require "rails_helper"

RSpec.describe ShippingReminderMailer, type: :mailer do
  let(:company) { create(:company, name: "Test Co") }
  let(:store) { create(:shopify_store, company: company) }
  let(:order) { create(:order, shopify_store: store) }
  let(:fulfillment) do
    create(:fulfillment, order: order, tracking_number: "TRACK123",
           destination_country: "United States", shipped_at: 20.days.ago,
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

    it "includes rule type heading" do
      expect(mail.body.encoded).to include("Not delivered for over X days")
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
  end
end
