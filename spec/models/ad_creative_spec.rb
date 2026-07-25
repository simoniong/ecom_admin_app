require "rails_helper"

RSpec.describe AdCreative do
  it "requires a unique asset per account, type and id" do
    account = create(:ad_account)
    create(:ad_creative, ad_account: account, asset_type: "video", asset_id: "v1")
    dup = build(:ad_creative, ad_account: account, asset_type: "video", asset_id: "v1")

    expect(dup).not_to be_valid
    expect(dup.errors[:asset_id]).to be_present
  end

  it "allows the same asset_id under a different asset_type" do
    account = create(:ad_account)
    create(:ad_creative, ad_account: account, asset_type: "video", asset_id: "shared")

    expect(build(:ad_creative, ad_account: account, asset_type: "image", asset_id: "shared")).to be_valid
  end

  it "rejects an unknown asset_type" do
    expect(build(:ad_creative, asset_type: "carousel")).not_to be_valid
  end

  it "nullifies ad_units instead of destroying them" do
    creative = create(:ad_creative)
    unit = create(:ad_unit, ad_account: creative.ad_account, ad_creative: creative)

    creative.destroy!

    expect(unit.reload.ad_creative_id).to be_nil
  end
end
