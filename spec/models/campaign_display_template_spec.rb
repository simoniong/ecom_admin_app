require "rails_helper"

RSpec.describe CampaignDisplayTemplate, type: :model do
  let(:user) { create(:user) }
  let(:template) { create(:campaign_display_template, user: user) }

  it "is valid with valid attributes" do
    expect(template).to be_valid
  end

  it "generates a UUID id" do
    expect(template.id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  it "belongs to user" do
    expect(template.user).to eq(user)
  end

  it "requires name" do
    template.name = ""
    expect(template).not_to be_valid
  end

  it "requires visible_columns" do
    template.visible_columns = nil
    expect(template).not_to be_valid
  end

  describe ".by_last_active" do
    it "orders by last_active_at descending" do
      old = create(:campaign_display_template, user: user, last_active_at: 2.days.ago)
      recent = create(:campaign_display_template, user: user, last_active_at: 1.hour.ago)
      expect(described_class.by_last_active).to eq([ recent, old ])
    end
  end

  describe "#touch_active!" do
    it "updates last_active_at to current time" do
      template.update!(last_active_at: 1.day.ago)
      template.touch_active!
      expect(template.reload.last_active_at).to be_within(2.seconds).of(Time.current)
    end
  end

  describe "#column_visible?" do
    it "returns true for included columns" do
      template.visible_columns = %w[impressions clicks]
      expect(template.column_visible?(:impressions)).to be true
    end

    it "returns false for excluded columns" do
      template.visible_columns = %w[impressions]
      expect(template.column_visible?(:clicks)).to be false
    end
  end

  describe "associations" do
    it "is destroyed with user" do
      create(:campaign_display_template, user: user)
      expect { user.destroy }.to change(described_class, :count).by(-1)
    end
  end
end
