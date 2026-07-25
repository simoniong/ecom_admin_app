require "rails_helper"

RSpec.describe AdUnit do
  it "requires a unique ad_id per account" do
    account = create(:ad_account)
    create(:ad_unit, ad_account: account, ad_id: "ad_1")

    expect(build(:ad_unit, ad_account: account, ad_id: "ad_1")).not_to be_valid
  end

  it "allows a null creative for multi-asset ads" do
    expect(build(:ad_unit, ad_creative: nil, multi_asset: true)).to be_valid
  end

  it "destroys its daily metrics" do
    unit = create(:ad_unit)
    create(:ad_unit_daily_metric, ad_unit: unit)

    expect { unit.destroy! }.to change(AdUnitDailyMetric, :count).by(-1)
  end
end
