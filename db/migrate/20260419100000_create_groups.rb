class CreateGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :groups, id: :uuid do |t|
      t.references :company, null: false, foreign_key: true, type: :uuid
      t.string :name, null: false
      t.text :description
      t.integer :position, default: 0, null: false

      t.timestamps
    end

    add_index :groups, [ :company_id, :name ], unique: true
  end
end
