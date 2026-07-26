require "rails_helper"

RSpec.describe AdUnitDailyMetric do
  it "requires a unique date per ad unit" do
    unit = create(:ad_unit)
    create(:ad_unit_daily_metric, ad_unit: unit, date: Date.new(2026, 7, 1))

    expect(build(:ad_unit_daily_metric, ad_unit: unit, date: Date.new(2026, 7, 1))).not_to be_valid
  end

  it "rejects negative spend" do
    expect(build(:ad_unit_daily_metric, spend: -1)).not_to be_valid
  end
end
