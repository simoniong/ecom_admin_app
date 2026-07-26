require "rails_helper"

RSpec.describe PackagesHelper, type: :helper do
  describe "#shopify_image_variant" do
    it "inserts the size before the extension" do
      url = "https://cdn.shopify.com/s/files/1/0033/4807/products/painting.jpg"

      expect(helper.shopify_image_variant(url, "100x100"))
        .to eq("https://cdn.shopify.com/s/files/1/0033/4807/products/painting_100x100.jpg")
    end

    # ?v= is Shopify's cache buster. Dropping it serves a stale image after the
    # merchant replaces the picture, so the query string has to survive.
    it "keeps the query string" do
      url = "https://cdn.shopify.com/s/files/1/0033/painting.jpg?v=1699999999"

      expect(helper.shopify_image_variant(url, "400x400"))
        .to eq("https://cdn.shopify.com/s/files/1/0033/painting_400x400.jpg?v=1699999999")
    end

    it "handles an uppercase extension" do
      url = "https://cdn.shopify.com/s/files/1/0033/PAINTING.JPG"

      expect(helper.shopify_image_variant(url, "100x100"))
        .to eq("https://cdn.shopify.com/s/files/1/0033/PAINTING_100x100.JPG")
    end

    it "handles the other formats Shopify serves" do
      %w[png webp gif jpeg].each do |ext|
        url = "https://cdn.shopify.com/s/files/1/art.#{ext}"

        expect(helper.shopify_image_variant(url, "100x100"))
          .to eq("https://cdn.shopify.com/s/files/1/art_100x100.#{ext}")
      end
    end

    # Guessing at an unrecognized URL shape produces a broken link — a missing
    # image. Returning the original produces a slow image. Slow beats missing.
    it "returns a URL with no recognizable extension untouched" do
      url = "https://example.com/images/12345"

      expect(helper.shopify_image_variant(url, "100x100")).to eq(url)
    end

    it "does not treat a dot in the path as an extension" do
      url = "https://cdn.example.com/v1.2/image"

      expect(helper.shopify_image_variant(url, "100x100")).to eq(url)
    end

    it "returns nil for nil" do
      expect(helper.shopify_image_variant(nil, "100x100")).to be_nil
    end

    it "returns nil for a blank string" do
      expect(helper.shopify_image_variant("   ", "100x100")).to be_nil
    end
  end
end
