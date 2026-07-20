class CreateLogisticsChannels < ActiveRecord::Migration[8.1]
  def change
    create_table :logistics_channels, id: :uuid do |t|
      t.references :logistics_account, type: :uuid, null: false, foreign_key: true
      t.string :name, null: false                 # 別稱, shown in packing module
      t.string :product_id, null: false           # Raydo 運輸方式ID
      t.string :product_shortname                 # Raydo short name, reference
      t.string :shopify_carrier_name, null: false, default: "Other"
      t.string :tracking_url_template, null: false, default: "https://t.17track.net/en#nums=#TrackingNumber#"
      t.timestamps
    end
  end
end
