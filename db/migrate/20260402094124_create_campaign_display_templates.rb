class CreateCampaignDisplayTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :campaign_display_templates, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.jsonb :visible_columns, null: false, default: []
      t.datetime :last_active_at

      t.timestamps
    end

    add_index :campaign_display_templates, [ :user_id, :last_active_at ]
  end
end
