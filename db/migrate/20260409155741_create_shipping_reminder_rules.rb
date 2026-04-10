class CreateShippingReminderRules < ActiveRecord::Migration[8.1]
  def change
    create_table :shipping_reminder_rules, id: :uuid do |t|
      t.references :company, null: false, foreign_key: true, type: :uuid
      t.string :rule_type, null: false
      t.boolean :enabled, default: true, null: false
      t.jsonb :country_thresholds, default: [], null: false

      t.timestamps
    end

    add_index :shipping_reminder_rules, [ :company_id, :rule_type ], unique: true
  end
end
