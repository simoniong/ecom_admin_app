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

ActiveRecord::Schema[8.1].define(version: 2026_04_02_094124) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "ad_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "access_token", null: false
    t.string "account_id", null: false
    t.string "account_name"
    t.datetime "created_at", null: false
    t.string "platform", default: "meta", null: false
    t.uuid "shopify_store_id"
    t.string "timezone", default: "UTC", null: false
    t.datetime "token_expires_at"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["shopify_store_id"], name: "index_ad_accounts_on_shopify_store_id"
    t.index ["user_id", "platform", "account_id"], name: "index_ad_accounts_on_user_id_and_platform_and_account_id", unique: true
    t.index ["user_id"], name: "index_ad_accounts_on_user_id"
  end

  create_table "ad_campaign_daily_metrics", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "ad_campaign_id", null: false
    t.integer "add_to_cart", default: 0
    t.integer "checkout_initiated", default: 0
    t.integer "clicks", default: 0
    t.decimal "conversion_value", precision: 12, scale: 2, default: "0.0"
    t.datetime "created_at", null: false
    t.date "date", null: false
    t.integer "impressions", default: 0
    t.integer "purchases", default: 0
    t.decimal "spend", precision: 12, scale: 2, default: "0.0"
    t.datetime "updated_at", null: false
    t.index ["ad_campaign_id", "date"], name: "idx_campaign_metrics_campaign_date", unique: true
    t.index ["ad_campaign_id"], name: "index_ad_campaign_daily_metrics_on_ad_campaign_id"
  end

  create_table "ad_campaigns", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "ad_account_id", null: false
    t.string "campaign_id", null: false
    t.string "campaign_name"
    t.datetime "created_at", null: false
    t.decimal "daily_budget", precision: 12, scale: 2, default: "0.0"
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["ad_account_id", "campaign_id"], name: "index_ad_campaigns_on_ad_account_id_and_campaign_id", unique: true
    t.index ["ad_account_id"], name: "index_ad_campaigns_on_ad_account_id"
  end

  create_table "ad_daily_metrics", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "ad_account_id", null: false
    t.integer "clicks", default: 0
    t.decimal "conversion_value", precision: 12, scale: 2, default: "0.0"
    t.integer "conversions", default: 0
    t.datetime "created_at", null: false
    t.date "date", null: false
    t.integer "impressions", default: 0
    t.decimal "spend", precision: 12, scale: 2, default: "0.0"
    t.datetime "updated_at", null: false
    t.index ["ad_account_id", "date"], name: "index_ad_daily_metrics_on_ad_account_id_and_date", unique: true
    t.index ["ad_account_id"], name: "index_ad_daily_metrics_on_ad_account_id"
  end

  create_table "campaign_display_templates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_active_at"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.jsonb "visible_columns", default: [], null: false
    t.index ["user_id", "last_active_at"], name: "index_campaign_display_templates_on_user_id_and_last_active_at"
    t.index ["user_id"], name: "index_campaign_display_templates_on_user_id"
  end

  create_table "customers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.string "first_name"
    t.string "last_name"
    t.string "phone"
    t.bigint "shopify_customer_id", null: false
    t.jsonb "shopify_data", default: {}
    t.string "timezone", default: "UTC", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_customers_on_email"
    t.index ["shopify_customer_id"], name: "index_customers_on_shopify_customer_id", unique: true
  end

  create_table "email_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "access_token", null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "google_uid", null: false
    t.bigint "last_history_id"
    t.datetime "last_synced_at"
    t.text "refresh_token", null: false
    t.text "scopes"
    t.uuid "shopify_store_id"
    t.datetime "token_expires_at"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["google_uid"], name: "index_email_accounts_on_google_uid", unique: true
    t.index ["shopify_store_id"], name: "index_email_accounts_on_shopify_store_id"
    t.index ["user_id", "email"], name: "index_email_accounts_on_user_id_and_email", unique: true
    t.index ["user_id"], name: "index_email_accounts_on_user_id"
  end

  create_table "fulfillments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "order_id", null: false
    t.jsonb "shopify_data", default: {}
    t.bigint "shopify_fulfillment_id", null: false
    t.string "status"
    t.string "tracking_company"
    t.jsonb "tracking_details", default: {}
    t.string "tracking_number"
    t.string "tracking_url"
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_fulfillments_on_order_id"
    t.index ["shopify_fulfillment_id"], name: "index_fulfillments_on_shopify_fulfillment_id", unique: true
    t.index ["tracking_number"], name: "index_fulfillments_on_tracking_number"
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

  create_table "orders", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency"
    t.uuid "customer_id", null: false
    t.string "email"
    t.string "financial_status"
    t.string "fulfillment_status"
    t.string "name"
    t.datetime "ordered_at"
    t.jsonb "shopify_data", default: {}
    t.bigint "shopify_order_id", null: false
    t.decimal "total_price", precision: 10, scale: 2
    t.datetime "updated_at", null: false
    t.index ["customer_id"], name: "index_orders_on_customer_id"
    t.index ["shopify_order_id"], name: "index_orders_on_shopify_order_id", unique: true
  end

  create_table "shopify_daily_metrics", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.decimal "conversion_rate", precision: 5, scale: 4, default: "0.0"
    t.datetime "created_at", null: false
    t.date "date", null: false
    t.integer "orders_count", default: 0
    t.decimal "revenue", precision: 12, scale: 2, default: "0.0"
    t.integer "sessions", default: 0
    t.uuid "shopify_store_id", null: false
    t.datetime "updated_at", null: false
    t.index ["shopify_store_id", "date"], name: "idx_shopify_metrics_store_date", unique: true
    t.index ["shopify_store_id"], name: "index_shopify_daily_metrics_on_shopify_store_id"
  end

  create_table "shopify_stores", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "access_token", null: false
    t.datetime "created_at", null: false
    t.datetime "installed_at"
    t.string "scopes"
    t.string "shop_domain", null: false
    t.string "timezone", default: "UTC", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["shop_domain"], name: "index_shopify_stores_on_shop_domain", unique: true
    t.index ["user_id"], name: "index_shopify_stores_on_user_id"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "tickets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "customer_email", null: false
    t.uuid "customer_id"
    t.string "customer_name"
    t.text "draft_reply"
    t.datetime "draft_reply_at"
    t.uuid "email_account_id", null: false
    t.string "gmail_thread_id", null: false
    t.datetime "last_message_at"
    t.integer "position", default: 0, null: false
    t.string "scheduled_job_id"
    t.datetime "scheduled_send_at"
    t.integer "status", default: 0, null: false
    t.string "subject"
    t.datetime "updated_at", null: false
    t.index ["customer_id"], name: "index_tickets_on_customer_id"
    t.index ["email_account_id", "gmail_thread_id"], name: "index_tickets_on_email_account_id_and_gmail_thread_id", unique: true
    t.index ["email_account_id"], name: "index_tickets_on_email_account_id"
    t.index ["last_message_at"], name: "index_tickets_on_last_message_at"
    t.index ["scheduled_send_at"], name: "index_tickets_on_scheduled_send_at"
    t.index ["status", "position"], name: "index_tickets_on_status_and_position"
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

  add_foreign_key "ad_accounts", "shopify_stores"
  add_foreign_key "ad_accounts", "users"
  add_foreign_key "ad_campaign_daily_metrics", "ad_campaigns"
  add_foreign_key "ad_campaigns", "ad_accounts"
  add_foreign_key "ad_daily_metrics", "ad_accounts"
  add_foreign_key "campaign_display_templates", "users"
  add_foreign_key "email_accounts", "shopify_stores"
  add_foreign_key "email_accounts", "users"
  add_foreign_key "fulfillments", "orders"
  add_foreign_key "messages", "tickets"
  add_foreign_key "orders", "customers"
  add_foreign_key "shopify_stores", "users"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "tickets", "customers"
  add_foreign_key "tickets", "email_accounts"
end
