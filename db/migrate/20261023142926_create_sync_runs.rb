class CreateSyncRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :sync_runs, id: :uuid do |t|
      t.references :company, null: false, foreign_key: true, type: :uuid
      t.string :source, null: false
      t.string :target_type, null: false
      t.uuid :target_id, null: false
      t.string :trigger, null: false
      t.string :status, null: false
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.text :error_message

      t.timestamps
    end

    add_index :sync_runs, [ :company_id, :source, :target_type, :target_id, :started_at ],
      name: "idx_sync_runs_on_company_source_target_started_at"
  end
end
