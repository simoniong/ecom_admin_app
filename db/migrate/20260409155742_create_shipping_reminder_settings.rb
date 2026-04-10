class CreateShippingReminderSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :shipping_reminder_settings, id: :uuid do |t|
      t.references :company, null: false, foreign_key: true, type: :uuid, index: { unique: true }
      t.boolean :enabled, default: false, null: false
      t.string :recipients, array: true, default: [], null: false
      t.string :timezone, default: "UTC", null: false
      t.integer :send_hour, default: 9, null: false
      t.string :frequency, default: "every_day", null: false
      t.integer :send_day_of_week
      t.datetime :last_sent_at

      t.timestamps
    end
  end
end
