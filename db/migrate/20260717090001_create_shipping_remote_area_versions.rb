class CreateShippingRemoteAreaVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :shipping_remote_area_versions, id: :uuid do |t|
      t.uuid :company_id, null: false
      t.string :country_code, null: false
      t.string :name, null: false
      t.date :effective_from, null: false
      t.date :effective_to
      t.timestamps
    end
    add_index :shipping_remote_area_versions, [ :company_id, :country_code, :effective_from ],
              name: "idx_remote_area_versions_lookup"
    add_foreign_key :shipping_remote_area_versions, :companies
  end
end
