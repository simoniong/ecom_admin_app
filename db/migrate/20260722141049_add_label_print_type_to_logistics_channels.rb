class AddLabelPrintTypeToLogisticsChannels < ActiveRecord::Migration[8.1]
  def change
    add_column :logistics_channels, :label_print_type, :string, null: false, default: "lab10_10"
  end
end
