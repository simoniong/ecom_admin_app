# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_03_26_030242) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "email_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "access_token", null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "google_uid", null: false
    t.bigint "last_history_id"
    t.datetime "last_synced_at"
    t.text "refresh_token", null: false
    t.text "scopes"
    t.datetime "token_expires_at"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["google_uid"], name: "index_email_accounts_on_google_uid", unique: true
    t.index ["user_id", "email"], name: "index_email_accounts_on_user_id_and_email", unique: true
    t.index ["user_id"], name: "index_email_accounts_on_user_id"
  end

  create_table "messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "body"
    t.string "cc"
    t.datetime "created_at", null: false
    t.string "from", null: false
    t.bigint "gmail_internal_date"
    t.string "gmail_message_id", null: false
    t.datetime "sent_at"
    t.string "subject"
    t.uuid "ticket_id", null: false
    t.string "to"
    t.datetime "updated_at", null: false
    t.index ["gmail_message_id"], name: "index_messages_on_gmail_message_id", unique: true
    t.index ["ticket_id", "sent_at"], name: "index_messages_on_ticket_id_and_sent_at"
    t.index ["ticket_id"], name: "index_messages_on_ticket_id"
  end

  create_table "tickets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "customer_email", null: false
    t.string "customer_name"
    t.uuid "email_account_id", null: false
    t.string "gmail_thread_id", null: false
    t.datetime "last_message_at"
    t.integer "status", default: 0, null: false
    t.string "subject"
    t.datetime "updated_at", null: false
    t.index ["email_account_id", "gmail_thread_id"], name: "index_tickets_on_email_account_id_and_gmail_thread_id", unique: true
    t.index ["email_account_id"], name: "index_tickets_on_email_account_id"
    t.index ["last_message_at"], name: "index_tickets_on_last_message_at"
    t.index ["status"], name: "index_tickets_on_status"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.integer "failed_attempts", default: 0, null: false
    t.datetime "locked_at"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.string "unlock_token"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["unlock_token"], name: "index_users_on_unlock_token", unique: true
  end

  add_foreign_key "email_accounts", "users"
  add_foreign_key "messages", "tickets"
  add_foreign_key "tickets", "email_accounts"
end
