require "rails_helper"

RSpec.describe LogisticsChannel, type: :model do
  let(:logistics_account) { create(:logistics_account) }
  let(:channel) { create(:logistics_channel, logistics_account: logistics_account) }

  it "is valid with valid attributes" do
    expect(channel).to be_valid
  end

  it "generates a UUID id" do
    expect(channel.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  it "belongs to logistics_account" do
    expect(channel.logistics_account).to eq(logistics_account)
  end

  it "has a company through logistics_account" do
    expect(channel.company).to eq(logistics_account.company)
  end

  describe "validations" do
    it "requires name" do
      channel.name = nil
      expect(channel).not_to be_valid
    end

    it "requires product_id" do
      channel.product_id = nil
      expect(channel).not_to be_valid
    end

    it "requires shopify_carrier_name" do
      channel.shopify_carrier_name = nil
      expect(channel).not_to be_valid
    end

    it "requires tracking_url_template" do
      channel.tracking_url_template = nil
      expect(channel).not_to be_valid
    end
  end

  describe "defaults" do
    it "defaults shopify_carrier_name to Other" do
      created = LogisticsChannel.create!(
        logistics_account: logistics_account,
        name: "Default channel",
        product_id: "PID-DEFAULT"
      )
      expect(created.shopify_carrier_name).to eq("Other")
    end

    it "defaults tracking_url_template to the 17track template" do
      created = LogisticsChannel.create!(
        logistics_account: logistics_account,
        name: "Default channel 2",
        product_id: "PID-DEFAULT2"
      )
      expect(created.tracking_url_template).to eq("https://t.17track.net/en#nums=#TrackingNumber#")
    end
  end

  describe "label_print_type" do
    it "defaults to lab10_10" do
      expect(create(:logistics_channel).label_print_type).to eq("lab10_10")
    end

    it "is required" do
      channel = build(:logistics_channel, label_print_type: "")
      expect(channel).not_to be_valid
      expect(channel.errors[:label_print_type]).to be_present
    end
  end
end
