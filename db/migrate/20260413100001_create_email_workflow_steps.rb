class CreateEmailWorkflowSteps < ActiveRecord::Migration[8.0]
  def change
    create_table :email_workflow_steps, id: :uuid do |t|
      t.references :email_workflow, null: false, foreign_key: true, type: :uuid
      t.integer :position, null: false, default: 0
      t.string :step_type, null: false
      t.jsonb :config, default: {}, null: false

      t.timestamps
    end

    add_index :email_workflow_steps, [ :email_workflow_id, :position ]
  end
end
