class AddBatchToSyncRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :sync_runs, :batch_id, :uuid
    add_column :sync_runs, :placeholder, :boolean, null: false, default: false

    add_index :sync_runs, [ :batch_id, :source, :target_type, :target_id ],
      name: "idx_sync_runs_on_batch_source_target"
  end
end
