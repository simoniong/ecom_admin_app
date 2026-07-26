class ChangePackagesOrderIdIndexNonUnique < ActiveRecord::Migration[8.1]
  def up
    remove_index :packages, name: "index_packages_on_order_id_unique"
    add_index :packages, :order_id, name: "index_packages_on_order_id"
  end

  def down
    remove_index :packages, name: "index_packages_on_order_id"
    add_index :packages, :order_id, unique: true, name: "index_packages_on_order_id_unique"
  end
end
