require "rails_helper"
RSpec.describe ShippingRemoteAreaRule do
  it "requires postal_start, postal_end, surcharge_cny and a non-negative surcharge" do
    r = ShippingRemoteAreaRule.new
    expect(r).not_to be_valid
    r = build(:shipping_remote_area_rule, surcharge_cny: -1)
    expect(r).not_to be_valid
  end

  it "rejects postal_end before postal_start" do
    r = build(:shipping_remote_area_rule, postal_start: "IV99", postal_end: "IV00")
    expect(r).not_to be_valid
  end
end
