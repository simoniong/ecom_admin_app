require "rails_helper"

RSpec.describe SyncShopifyProductsService do
  let(:store) { create(:shopify_store) }
  let(:shopify_service) { instance_double(ShopifyService) }
  let(:service) { described_class.new(store) }

  before do
    allow(ShopifyService).to receive(:new).with(store).and_return(shopify_service)
    allow(shopify_service).to receive(:fetch_shop).and_return({ "currency" => "USD", "name" => "Paint Kit Studio" })
  end

  let(:variant_a) do
    { "id" => 8001, "sku" => "PK-BL", "title" => "Black/Large", "price" => "29.00" }
  end
  let(:variant_b) do
    { "id" => 8002, "sku" => "PK-BS", "title" => "Black/Small", "price" => "24.00" }
  end
  let(:product_payload) do
    { "id" => 7001, "title" => "Paint Kit", "handle" => "paint-kit",
      "status" => "active", "image" => { "src" => "https://cdn/x.jpg" },
      "variants" => [ variant_a, variant_b ] }
  end

  before do
    allow(shopify_service).to receive(:fetch_all_products).and_return([ product_payload ], [])
  end

  it "creates products" do
    service.call
    p = Product.find_by(shopify_product_id: 7001)
    expect(p).to be_present
    expect(p.shopify_store).to eq(store)
    expect(p.title).to eq("Paint Kit")
    expect(p.handle).to eq("paint-kit")
    expect(p.status).to eq("active")
    expect(p.image_url).to eq("https://cdn/x.jpg")
  end

  it "creates variants under the product" do
    service.call
    p = Product.find_by(shopify_product_id: 7001)
    expect(p.product_variants.count).to eq(2)
    v = p.product_variants.find_by(shopify_variant_id: 8001)
    expect(v.sku).to eq("PK-BL")
    expect(v.title).to eq("Black/Large")
    expect(v.price).to eq(29.00)
    expect(v.currency).to eq("USD")
  end

  it "leaves unit_cost and weight_grams nil — admin must set them in the UI" do
    service.call
    v = ProductVariant.find_by(shopify_variant_id: 8001)
    expect(v.unit_cost).to be_nil
    expect(v.weight_grams).to be_nil
  end

  it "updates store currency from /shop.json" do
    expect { service.call }.to change { store.reload.currency }.to("USD")
  end

  it "updates store name from /shop.json" do
    expect { service.call }.to change { store.reload.name }.to("Paint Kit Studio")
  end

  it "sets products_synced_at" do
    expect { service.call }.to change { store.reload.products_synced_at }.from(nil)
  end

  it "returns counts" do
    expect(service.call).to eq(products: 1, variants: 2)
  end

  it "is idempotent — no duplicates on re-run" do
    service.call
    allow(shopify_service).to receive(:fetch_all_products).and_return([ product_payload ], [])
    expect { described_class.new(store).call }.not_to change(Product, :count)
  end

  it "does not overwrite admin-edited unit_cost or weight_grams" do
    service.call
    v = ProductVariant.find_by(shopify_variant_id: 8001)
    v.update!(unit_cost: 99.99, weight_grams: 500)

    allow(shopify_service).to receive(:fetch_all_products).and_return([ product_payload ], [])
    described_class.new(store).call

    v.reload
    expect(v.unit_cost).to eq(99.99)
    expect(v.weight_grams).to eq(500)
  end
end
