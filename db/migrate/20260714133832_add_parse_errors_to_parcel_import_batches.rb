class AddParseErrorsToParcelImportBatches < ActiveRecord::Migration[8.1]
  def change
    # Parse errors (the skipped rows) belong to the staged batch, not to a
    # single request: under Post/Redirect/Get the preview page is rendered by a
    # later GET and must stay reloadable, so they have to be persisted rather
    # than carried in the flash.
    add_column :parcel_import_batches, :parse_errors, :jsonb, default: [], null: false
  end
end
