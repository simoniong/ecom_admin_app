require "rails_helper"
RSpec.describe PackageItem do
  it "requires a positive integer quantity" do
    expect(build(:package_item, quantity: 0)).not_to be_valid
    expect(build(:package_item, quantity: 2)).to be_valid
  end
end
