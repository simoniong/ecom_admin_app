require "rails_helper"

RSpec.describe ParcelsHelper, type: :helper do
  describe "#parcel_weight_comparison" do
    # Regression: the old check was a bare `billed > order`, so a parcel
    # LIGHTER than the goods fell into the same branch as an exact match and
    # was labelled "matches" — hiding the very difference the estimate columns
    # were reporting either side of it.
    it "reports a lighter parcel as :lighter, not as a match" do
      expect(helper.parcel_weight_comparison(1.207, 1.26)).to eq(:lighter)
    end

    it "reports a heavier parcel as :heavier" do
      expect(helper.parcel_weight_comparison(1.31, 1.26)).to eq(:heavier)
    end

    it "reports identical weights as :matches" do
      expect(helper.parcel_weight_comparison(1.26, 1.26)).to eq(:matches)
    end

    it "treats a difference invisible at the displayed precision as a match" do
      # Both render as "1.26 kg", so calling them different would be noise.
      expect(helper.parcel_weight_comparison(1.2612, 1.26)).to eq(:matches)
      expect(helper.parcel_weight_comparison(1.2588, 1.26)).to eq(:matches)
    end

    it "reports a difference at the displayed precision" do
      expect(helper.parcel_weight_comparison(1.266, 1.26)).to eq(:heavier)
      expect(helper.parcel_weight_comparison(1.254, 1.26)).to eq(:lighter)
    end

    it "falls back to :matches when either weight is unknown" do
      expect(helper.parcel_weight_comparison(nil, 1.26)).to eq(:matches)
      expect(helper.parcel_weight_comparison(1.26, nil)).to eq(:matches)
    end
  end
end
