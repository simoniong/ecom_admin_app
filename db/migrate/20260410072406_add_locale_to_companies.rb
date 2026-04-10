class AddLocaleToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :locale, :string, default: "en", null: false
  end
end
