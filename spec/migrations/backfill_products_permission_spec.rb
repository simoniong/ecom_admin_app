require "rails_helper"

migration_path = Rails.root.join("db/migrate/20260720092412_backfill_products_permission.rb")
require migration_path

RSpec.describe BackfillProductsPermission do
  subject(:migration) { described_class.new }

  def permissions_for(membership)
    membership.reload.permissions
  end

  describe "#up" do
    it "adds products to memberships that already have shopify_stores" do
      membership = create(:membership, role: :member, permissions: [ "shopify_stores" ])

      migration.up

      expect(permissions_for(membership)).to contain_exactly("shopify_stores", "products")
    end

    it "does not touch memberships without shopify_stores" do
      membership = create(:membership, role: :member, permissions: [ "orders" ])

      migration.up

      expect(permissions_for(membership)).to eq([ "orders" ])
    end

    it "leaves memberships that already have products untouched (idempotent within a single run)" do
      membership = create(:membership, role: :member, permissions: [ "shopify_stores", "products" ])

      migration.up

      expect(permissions_for(membership)).to contain_exactly("shopify_stores", "products")
    end

    it "does not duplicate the products entry when run twice" do
      membership = create(:membership, role: :member, permissions: [ "shopify_stores" ])

      migration.up
      migration.up

      expect(permissions_for(membership).count("products")).to eq(1)
      expect(permissions_for(membership)).to contain_exactly("shopify_stores", "products")
    end

    it "does not affect memberships with no permissions" do
      membership = create(:membership, role: :member, permissions: [])

      migration.up

      expect(permissions_for(membership)).to eq([])
    end
  end

  describe "#down" do
    it "removes products from memberships that also have shopify_stores" do
      membership = create(:membership, role: :member, permissions: [ "shopify_stores", "products" ])

      migration.down

      expect(permissions_for(membership)).to eq([ "shopify_stores" ])
    end

    it "leaves products in place for memberships without shopify_stores" do
      membership = create(:membership, role: :member, permissions: [ "products" ])

      migration.down

      expect(permissions_for(membership)).to eq([ "products" ])
    end

    it "round-trips: up then down restores the original state" do
      membership = create(:membership, role: :member, permissions: [ "shopify_stores" ])

      migration.up
      expect(permissions_for(membership)).to contain_exactly("shopify_stores", "products")

      migration.down
      expect(permissions_for(membership)).to eq([ "shopify_stores" ])
    end
  end
end
