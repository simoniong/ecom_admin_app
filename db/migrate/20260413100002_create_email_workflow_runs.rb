class CreateEmailWorkflowRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :email_workflow_runs, id: :uuid do |t|
      t.references :email_workflow, null: false, foreign_key: true, type: :uuid
      t.references :order, null: false, foreign_key: true, type: :uuid
      t.references :ticket, null: false, foreign_key: true, type: :uuid
      t.integer :current_step_position, default: 0, null: false
      t.string :status, default: "running", null: false
      t.string :cancelled_reason
      t.string :scheduled_job_id
      t.datetime :started_at, null: false
      t.datetime :completed_at

      t.timestamps
    end

    add_index :email_workflow_runs, [ :email_workflow_id, :order_id ], unique: true
    add_index :email_workflow_runs, :status
  end
end
