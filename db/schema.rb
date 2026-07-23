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

ActiveRecord::Schema[8.1].define(version: 2026_07_22_164525) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pgcrypto"

  create_table "ad_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "access_token", null: false
    t.string "account_id", null: false
    t.string "account_name"
    t.uuid "company_id", null: false
    t.datetime "created_at", null: false
    t.uuid "group_id"
    t.string "platform", default: "meta", null: false
    t.uuid "shopify_store_id"
    t.string "timezone", default: "UTC", null: false
    t.datetime "token_expires_at"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["company_id"], name: "index_ad_accounts_on_company_id"
    t.index ["group_id"], name: "index_ad_accounts_on_group_id"
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
    t.uuid "company_id", null: false
    t.datetime "created_at", null: false
    t.datetime "last_active_at"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.jsonb "visible_columns", default: [], null: false
    t.index ["company_id"], name: "index_campaign_display_templates_on_company_id"
    t.index ["user_id", "last_active_at"], name: "index_campaign_display_templates_on_user_id_and_last_active_at"
    t.index ["user_id"], name: "index_campaign_display_templates_on_user_id"
  end

  create_table "companies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "agent_api_key"
    t.datetime "created_at", null: false
    t.string "locale", default: "en", null: false
    t.string "name", null: false
    t.text "tracking_api_key"
    t.integer "tracking_backfill_days"
    t.boolean "tracking_enabled", default: false, null: false
    t.string "tracking_mode"
    t.datetime "tracking_starts_at"
    t.datetime "updated_at", null: false
    t.index ["agent_api_key"], name: "index_companies_on_agent_api_key", unique: true
  end

  create_table "customers", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.string "first_name"
    t.string "last_name"
    t.string "phone"
    t.bigint "shopify_customer_id", null: false
    t.jsonb "shopify_data", default: {}
    t.uuid "shopify_store_id"
    t.string "timezone", default: "UTC", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_customers_on_email"
    t.index ["shopify_store_id", "shopify_customer_id"], name: "idx_customers_store_shopify_id", unique: true
    t.index ["shopify_store_id"], name: "index_customers_on_shopify_store_id"
  end

  create_table "email_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "access_token", null: false
    t.string "agent_api_key", null: false
    t.uuid "company_id", null: false
    t.datetime "created_at", null: false
    t.string "discord_agent_mention"
    t.string "email", null: false
    t.string "google_uid", null: false
    t.uuid "group_id"
    t.bigint "last_history_id"
    t.datetime "last_synced_at"
    t.text "refresh_token", null: false
    t.text "scopes"
    t.integer "send_window_from_hour", default: 8, null: false
    t.integer "send_window_from_minute", default: 0, null: false
    t.integer "send_window_to_hour", default: 22, null: false
    t.integer "send_window_to_minute", default: 0, null: false
    t.uuid "shopify_store_id"
    t.datetime "token_expires_at"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["agent_api_key"], name: "index_email_accounts_on_agent_api_key", unique: true
    t.index ["company_id"], name: "index_email_accounts_on_company_id"
    t.index ["google_uid"], name: "index_email_accounts_on_google_uid", unique: true
    t.index ["group_id"], name: "index_email_accounts_on_group_id"
    t.index ["shopify_store_id"], name: "index_email_accounts_on_shopify_store_id"
    t.index ["user_id", "email"], name: "index_email_accounts_on_user_id_and_email", unique: true
    t.index ["user_id"], name: "index_email_accounts_on_user_id"
  end

  create_table "email_workflow_runs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "cancelled_reason"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "current_step_position", default: 0, null: false
    t.uuid "email_workflow_id", null: false
    t.uuid "order_id", null: false
    t.string "scheduled_job_id"
    t.datetime "started_at", null: false
    t.string "status", default: "running", null: false
    t.uuid "ticket_id", null: false
    t.datetime "updated_at", null: false
    t.index ["email_workflow_id", "order_id"], name: "index_email_workflow_runs_on_email_workflow_id_and_order_id", unique: true
    t.index ["email_workflow_id"], name: "index_email_workflow_runs_on_email_workflow_id"
    t.index ["order_id"], name: "index_email_workflow_runs_on_order_id"
    t.index ["status"], name: "index_email_workflow_runs_on_status"
    t.index ["ticket_id"], name: "index_email_workflow_runs_on_ticket_id"
  end

  create_table "email_workflow_steps", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.uuid "email_workflow_id", null: false
    t.integer "position", default: 0, null: false
    t.string "step_type", null: false
    t.datetime "updated_at", null: false
    t.index ["email_workflow_id", "position"], name: "index_email_workflow_steps_on_email_workflow_id_and_position"
    t.index ["email_workflow_id"], name: "index_email_workflow_steps_on_email_workflow_id"
  end

  create_table "email_workflows", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.uuid "shopify_store_id", null: false
    t.string "trigger_event", null: false
    t.datetime "updated_at", null: false
    t.index ["shopify_store_id", "trigger_event"], name: "index_email_workflows_on_shopify_store_id_and_trigger_event", unique: true
    t.index ["shopify_store_id"], name: "index_email_workflows_on_shopify_store_id"
  end

  create_table "fulfillments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "archived_at"
    t.integer "carrier_code"
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.string "destination_carrier"
    t.string "destination_country"
    t.datetime "last_event_at"
    t.string "latest_event_description"
    t.uuid "order_id", null: false
    t.string "origin_carrier"
    t.string "origin_country"
    t.datetime "shipped_at"
    t.jsonb "shopify_data", default: {}
    t.bigint "shopify_fulfillment_id", null: false
    t.string "status"
    t.string "tags", default: [], array: true
    t.string "tracking_company"
    t.jsonb "tracking_details", default: {}
    t.string "tracking_number"
    t.string "tracking_status"
    t.string "tracking_sub_status"
    t.string "tracking_url"
    t.integer "transit_days"
    t.datetime "updated_at", null: false
    t.index ["archived_at"], name: "index_fulfillments_on_archived_at"
    t.index ["delivered_at"], name: "index_fulfillments_on_delivered_at"
    t.index ["destination_carrier"], name: "index_fulfillments_on_destination_carrier"
    t.index ["destination_country"], name: "index_fulfillments_on_destination_country"
    t.index ["last_event_at"], name: "index_fulfillments_on_last_event_at"
    t.index ["order_id"], name: "index_fulfillments_on_order_id"
    t.index ["origin_carrier"], name: "index_fulfillments_on_origin_carrier"
    t.index ["shipped_at"], name: "index_fulfillments_on_shipped_at"
    t.index ["shopify_fulfillment_id"], name: "index_fulfillments_on_shopify_fulfillment_id", unique: true
    t.index ["tracking_number"], name: "index_fulfillments_on_tracking_number"
    t.index ["tracking_status"], name: "index_fulfillments_on_tracking_status"
    t.index ["transit_days"], name: "index_fulfillments_on_transit_days"
  end

  create_table "groups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "company_id", null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index "company_id, lower((name)::text)", name: "index_groups_on_company_id_and_lower_name", unique: true
    t.index ["company_id"], name: "index_groups_on_company_id"
  end

  create_table "invitations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "accepted_at"
    t.uuid "company_id", null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.uuid "group_id"
    t.uuid "invited_by_id", null: false
    t.jsonb "permissions", default: [], null: false
    t.integer "role", default: 0, null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "email"], name: "index_invitations_on_company_id_and_email", unique: true, where: "(accepted_at IS NULL)"
    t.index ["company_id"], name: "index_invitations_on_company_id"
    t.index ["group_id"], name: "index_invitations_on_group_id"
    t.index ["invited_by_id"], name: "index_invitations_on_invited_by_id"
    t.index ["token"], name: "index_invitations_on_token", unique: true
  end

  create_table "logistics_accounts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "company_id", null: false
    t.datetime "created_at", null: false
    t.string "customer_id"
    t.string "customer_userid"
    t.text "password"
    t.string "provider", default: "raydo", null: false
    t.datetime "updated_at", null: false
    t.string "url1_base"
    t.string "url2_base"
    t.string "username"
    t.index ["company_id", "provider"], name: "index_logistics_accounts_on_company_id_and_provider", unique: true
    t.index ["company_id"], name: "index_logistics_accounts_on_company_id"
  end

  create_table "logistics_channels", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "label_print_type", default: "lab10_10", null: false
    t.uuid "logistics_account_id", null: false
    t.string "name", null: false
    t.string "product_id", null: false
    t.string "product_shortname"
    t.string "shopify_carrier_name", default: "Other", null: false
    t.string "tracking_url_template", default: "https://t.17track.net/en#nums=#TrackingNumber#", null: false
    t.datetime "updated_at", null: false
    t.index ["logistics_account_id"], name: "index_logistics_channels_on_logistics_account_id"
  end

  create_table "memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "company_id", null: false
    t.datetime "created_at", null: false
    t.uuid "group_id"
    t.jsonb "permissions", default: [], null: false
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["company_id", "user_id"], name: "index_memberships_on_company_id_and_user_id", unique: true
    t.index ["company_id"], name: "index_memberships_on_company_id"
    t.index ["group_id"], name: "index_memberships_on_group_id"
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "bcc"
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

  create_table "order_line_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency"
    t.uuid "order_id", null: false
    t.uuid "product_variant_id"
    t.integer "quantity", null: false
    t.jsonb "shopify_data", default: {}
    t.bigint "shopify_line_item_id", null: false
    t.string "sku_at_sale"
    t.string "title_at_sale"
    t.decimal "unit_cost_snapshot", precision: 10, scale: 2
    t.decimal "unit_price", precision: 10, scale: 2
    t.datetime "updated_at", null: false
    t.index ["order_id", "shopify_line_item_id"], name: "idx_line_items_order_shopify_id", unique: true
    t.index ["product_variant_id"], name: "index_order_line_items_on_product_variant_id"
  end

  create_table "orders", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.decimal "actual_shipping_cost", precision: 10, scale: 2
    t.datetime "created_at", null: false
    t.string "currency"
    t.uuid "customer_id", null: false
    t.string "email"
    t.decimal "estimated_shipping_cost", precision: 10, scale: 2
    t.string "financial_status"
    t.string "fulfillment_status"
    t.string "name"
    t.datetime "ordered_at"
    t.jsonb "shopify_data", default: {}
    t.bigint "shopify_order_id", null: false
    t.uuid "shopify_store_id"
    t.decimal "total_price", precision: 10, scale: 2
    t.datetime "updated_at", null: false
    t.index ["customer_id"], name: "index_orders_on_customer_id"
    t.index ["shopify_store_id", "ordered_at"], name: "idx_orders_store_ordered_at"
    t.index ["shopify_store_id", "shopify_order_id"], name: "idx_orders_store_shopify_id", unique: true
    t.index ["shopify_store_id"], name: "index_orders_on_shopify_store_id"
  end

  create_table "package_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "customs_name_en"
    t.string "customs_name_zh"
    t.boolean "customs_overridden", default: false, null: false
    t.decimal "customs_weight_grams", precision: 12, scale: 3
    t.decimal "declared_value_usd", precision: 10, scale: 2
    t.string "hs_code"
    t.string "import_hs_code"
    t.uuid "order_line_item_id"
    t.uuid "package_id", null: false
    t.uuid "product_variant_id"
    t.integer "quantity", null: false
    t.integer "refunded_quantity", default: 0, null: false
    t.string "sku"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["order_line_item_id"], name: "index_package_items_on_order_line_item_id"
    t.index ["package_id"], name: "index_package_items_on_package_id"
    t.index ["product_variant_id"], name: "index_package_items_on_product_variant_id"
  end

  create_table "packages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "aasm_state", null: false
    t.boolean "address_overridden", default: false, null: false
    t.text "application_message"
    t.string "application_status", default: "none", null: false
    t.datetime "applied_at"
    t.string "carrier"
    t.datetime "carrier_marked_at"
    t.datetime "created_at", null: false
    t.string "held_from"
    t.uuid "logistics_channel_id"
    t.text "note"
    t.integer "number", null: false
    t.uuid "order_id", null: false
    t.string "raydo_order_id"
    t.text "ship_sync_message"
    t.string "ship_sync_status", default: "none", null: false
    t.datetime "shipped_at"
    t.jsonb "shipping_address_snapshot", default: {}, null: false
    t.string "shopify_fulfillment_id"
    t.uuid "shopify_store_id", null: false
    t.string "tracking_number"
    t.datetime "tracking_registered_at"
    t.datetime "updated_at", null: false
    t.index ["logistics_channel_id"], name: "index_packages_on_logistics_channel_id"
    t.index ["order_id"], name: "index_packages_on_order_id"
    t.index ["ship_sync_status"], name: "index_packages_on_ship_sync_status"
    t.index ["shopify_fulfillment_id"], name: "index_packages_on_shopify_fulfillment_id_unique", unique: true, where: "(shopify_fulfillment_id IS NOT NULL)"
    t.index ["shopify_store_id", "aasm_state"], name: "index_packages_on_shopify_store_id_and_aasm_state"
    t.index ["shopify_store_id", "number"], name: "index_packages_on_shopify_store_id_and_number", unique: true
    t.index ["shopify_store_id"], name: "index_packages_on_shopify_store_id"
  end

  create_table "parcel_import_batches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "filename"
    t.jsonb "parse_errors", default: [], null: false
    t.integer "row_count", default: 0, null: false
    t.jsonb "rows", default: [], null: false
    t.uuid "shopify_store_id", null: false
    t.string "status", default: "pending", null: false
    t.decimal "total_cny", precision: 12, scale: 2
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["shopify_store_id", "status"], name: "index_parcel_import_batches_on_shopify_store_id_and_status"
    t.index ["shopify_store_id"], name: "index_parcel_import_batches_on_shopify_store_id"
    t.index ["user_id"], name: "index_parcel_import_batches_on_user_id"
  end

  create_table "parcels", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "actual_weight_g"
    t.integer "billed_weight_g"
    t.decimal "cost_amount", precision: 10, scale: 2, null: false
    t.decimal "cost_cny", precision: 10, scale: 2
    t.string "country"
    t.datetime "created_at", null: false
    t.decimal "freight_cny", precision: 10, scale: 2
    t.decimal "fx_rate_snapshot", precision: 10, scale: 4
    t.string "identifier", null: false
    t.string "internal_no"
    t.decimal "operation_fee_cny", precision: 10, scale: 2
    t.uuid "order_id"
    t.decimal "registration_fee_cny", precision: 10, scale: 2
    t.decimal "remote_area_fee_cny", precision: 10, scale: 2
    t.string "service_channel"
    t.datetime "shipped_at"
    t.uuid "shopify_store_id", null: false
    t.decimal "tax_cny", precision: 10, scale: 2
    t.string "tracking_number"
    t.datetime "updated_at", null: false
    t.string "zone"
    t.index ["order_id"], name: "index_parcels_on_order_id"
    t.index ["shopify_store_id", "identifier"], name: "index_parcels_on_shopify_store_id_and_identifier", unique: true
    t.index ["shopify_store_id"], name: "index_parcels_on_shopify_store_id"
    t.index ["tracking_number"], name: "index_parcels_on_tracking_number"
  end

  create_table "product_variants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency"
    t.string "customs_name_en"
    t.string "customs_name_zh"
    t.decimal "declared_value_usd", precision: 10, scale: 2
    t.string "hs_code"
    t.string "import_hs_code"
    t.decimal "packaging_cost", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "price", precision: 10, scale: 2
    t.uuid "product_id", null: false
    t.jsonb "shopify_data", default: {}
    t.bigint "shopify_variant_id", null: false
    t.string "sku"
    t.string "title"
    t.decimal "unit_cost", precision: 10, scale: 2
    t.datetime "updated_at", null: false
    t.decimal "weight_grams", precision: 12, scale: 3
    t.index ["product_id", "shopify_variant_id"], name: "idx_variants_product_shopify_id", unique: true
    t.index ["sku"], name: "index_product_variants_on_sku"
  end

  create_table "products", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "handle"
    t.string "image_url"
    t.jsonb "shopify_data", default: {}
    t.bigint "shopify_product_id", null: false
    t.uuid "shopify_store_id", null: false
    t.string "status"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["shopify_store_id", "shopify_product_id"], name: "idx_products_store_shopify_id", unique: true
    t.index ["shopify_store_id"], name: "index_products_on_shopify_store_id"
  end

  create_table "shipping_rate_card_rates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "flat_fee_cny", precision: 10, scale: 2, default: "0.0", null: false
    t.decimal "per_kg_rate_cny", precision: 10, scale: 2, null: false
    t.datetime "updated_at", null: false
    t.uuid "version_id", null: false
    t.decimal "weight_max_kg", precision: 8, scale: 3, null: false
    t.decimal "weight_min_kg", precision: 8, scale: 3, null: false
    t.string "zone"
    t.index ["version_id", "zone"], name: "index_shipping_rate_card_rates_on_version_id_and_zone"
    t.index ["version_id"], name: "index_shipping_rate_card_rates_on_version_id"
  end

  create_table "shipping_rate_card_versions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "company_id", null: false
    t.string "country_code", null: false
    t.datetime "created_at", null: false
    t.date "effective_from", null: false
    t.date "effective_to"
    t.string "name", null: false
    t.string "service_type", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "country_code", "service_type", "effective_from"], name: "idx_rate_versions_lookup"
  end

  create_table "shipping_reminder_rules", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "company_id", null: false
    t.jsonb "country_thresholds", default: [], null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.string "rule_type", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "rule_type"], name: "index_shipping_reminder_rules_on_company_id_and_rule_type", unique: true
    t.index ["company_id"], name: "index_shipping_reminder_rules_on_company_id"
  end

  create_table "shipping_reminder_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "company_id", null: false
    t.datetime "created_at", null: false
    t.boolean "enabled", default: false, null: false
    t.string "frequency", default: "every_day", null: false
    t.datetime "last_sent_at"
    t.string "recipients", default: [], null: false, array: true
    t.integer "send_day_of_week"
    t.integer "send_hour", default: 9, null: false
    t.string "timezone", default: "UTC", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id"], name: "index_shipping_reminder_settings_on_company_id", unique: true
  end

  create_table "shipping_remote_area_rules", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "area_label"
    t.datetime "created_at", null: false
    t.string "postal_end", null: false
    t.string "postal_start", null: false
    t.decimal "surcharge_cny", precision: 10, scale: 2, null: false
    t.datetime "updated_at", null: false
    t.uuid "version_id", null: false
    t.index ["version_id", "postal_start"], name: "idx_remote_area_rules_lookup"
  end

  create_table "shipping_remote_area_versions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "company_id", null: false
    t.string "country_code", null: false
    t.datetime "created_at", null: false
    t.date "effective_from", null: false
    t.date "effective_to"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["company_id", "country_code", "effective_from"], name: "idx_remote_area_versions_lookup"
  end

  create_table "shipping_zone_postal_rules", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "company_id", null: false
    t.string "country_code", null: false
    t.datetime "created_at", null: false
    t.string "postal_end", null: false
    t.string "postal_start", null: false
    t.datetime "updated_at", null: false
    t.string "zone", null: false
    t.index ["company_id", "country_code", "postal_start"], name: "idx_zone_postal_lookup"
  end

  create_table "shopify_daily_metrics", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.decimal "conversion_rate", precision: 5, scale: 4, default: "0.0"
    t.datetime "created_at", null: false
    t.date "date", null: false
    t.decimal "gross_revenue", precision: 12, scale: 2, default: "0.0", null: false
    t.integer "new_customer_orders_count", default: 0, null: false
    t.integer "orders_count", default: 0
    t.decimal "refunds", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "revenue", precision: 12, scale: 2, default: "0.0"
    t.integer "sessions", default: 0
    t.uuid "shopify_store_id", null: false
    t.decimal "total_tax", precision: 12, scale: 2, default: "0.0", null: false
    t.decimal "transaction_fees", precision: 12, scale: 2, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["shopify_store_id", "date"], name: "idx_shopify_metrics_store_date", unique: true
    t.index ["shopify_store_id"], name: "index_shopify_daily_metrics_on_shopify_store_id"
  end

  create_table "shopify_stores", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "access_token", null: false
    t.string "client_id"
    t.text "client_secret"
    t.uuid "company_id", null: false
    t.decimal "cost_fx_rate", precision: 10, scale: 4
    t.datetime "created_at", null: false
    t.string "currency"
    t.string "default_service_type"
    t.uuid "group_id"
    t.datetime "installed_at"
    t.string "name"
    t.datetime "orders_synced_at"
    t.integer "package_number_seq"
    t.integer "package_number_start"
    t.string "package_prefix"
    t.boolean "packing_enabled", default: false, null: false
    t.datetime "packing_enabled_at"
    t.datetime "products_synced_at"
    t.string "scopes"
    t.boolean "shipping_sync_enabled", default: false, null: false
    t.string "shop_domain", null: false
    t.string "timezone", default: "UTC", null: false
    t.string "trustpilot_bcc_email"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.datetime "webhooks_registered_at"
    t.index ["company_id"], name: "index_shopify_stores_on_company_id"
    t.index ["group_id"], name: "index_shopify_stores_on_group_id"
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
    t.boolean "bcc_trustpilot", default: false, null: false
    t.datetime "created_at", null: false
    t.string "customer_email", null: false
    t.uuid "customer_id"
    t.string "customer_name"
    t.text "draft_reply"
    t.datetime "draft_reply_at"
    t.uuid "email_account_id", null: false
    t.string "gmail_thread_id"
    t.integer "initiated_by", default: 0, null: false
    t.datetime "last_message_at"
    t.uuid "order_id"
    t.integer "position", default: 0, null: false
    t.string "reopened_reason"
    t.string "scheduled_job_id"
    t.datetime "scheduled_send_at"
    t.datetime "sending_started_at"
    t.integer "status", default: 0, null: false
    t.string "subject"
    t.string "trustpilot_bcc_email"
    t.datetime "updated_at", null: false
    t.index ["customer_id"], name: "index_tickets_on_customer_id"
    t.index ["email_account_id", "gmail_thread_id"], name: "index_tickets_on_email_account_id_and_gmail_thread_id", unique: true, where: "(gmail_thread_id IS NOT NULL)"
    t.index ["email_account_id"], name: "index_tickets_on_email_account_id"
    t.index ["last_message_at"], name: "index_tickets_on_last_message_at"
    t.index ["order_id"], name: "index_tickets_on_order_id"
    t.index ["scheduled_send_at"], name: "index_tickets_on_scheduled_send_at"
    t.index ["status", "position"], name: "index_tickets_on_status_and_position"
    t.index ["status"], name: "index_tickets_on_status"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.integer "failed_attempts", default: 0, null: false
    t.string "first_name"
    t.string "last_name"
    t.string "locale", default: "en", null: false
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

  add_foreign_key "ad_accounts", "companies"
  add_foreign_key "ad_accounts", "groups"
  add_foreign_key "ad_accounts", "shopify_stores"
  add_foreign_key "ad_accounts", "users"
  add_foreign_key "ad_campaign_daily_metrics", "ad_campaigns"
  add_foreign_key "ad_campaigns", "ad_accounts"
  add_foreign_key "ad_daily_metrics", "ad_accounts"
  add_foreign_key "campaign_display_templates", "companies"
  add_foreign_key "campaign_display_templates", "users"
  add_foreign_key "customers", "shopify_stores"
  add_foreign_key "email_accounts", "companies"
  add_foreign_key "email_accounts", "groups"
  add_foreign_key "email_accounts", "shopify_stores"
  add_foreign_key "email_accounts", "users"
  add_foreign_key "email_workflow_runs", "email_workflows"
  add_foreign_key "email_workflow_runs", "orders"
  add_foreign_key "email_workflow_runs", "tickets"
  add_foreign_key "email_workflow_steps", "email_workflows"
  add_foreign_key "email_workflows", "shopify_stores"
  add_foreign_key "fulfillments", "orders"
  add_foreign_key "groups", "companies"
  add_foreign_key "invitations", "companies"
  add_foreign_key "invitations", "groups"
  add_foreign_key "invitations", "users", column: "invited_by_id"
  add_foreign_key "logistics_accounts", "companies"
  add_foreign_key "logistics_channels", "logistics_accounts"
  add_foreign_key "memberships", "companies"
  add_foreign_key "memberships", "groups"
  add_foreign_key "memberships", "users"
  add_foreign_key "messages", "tickets"
  add_foreign_key "order_line_items", "orders"
  add_foreign_key "order_line_items", "product_variants"
  add_foreign_key "orders", "customers"
  add_foreign_key "orders", "shopify_stores"
  add_foreign_key "package_items", "order_line_items"
  add_foreign_key "package_items", "packages"
  add_foreign_key "package_items", "product_variants"
  add_foreign_key "packages", "logistics_channels"
  add_foreign_key "packages", "orders"
  add_foreign_key "packages", "shopify_stores"
  add_foreign_key "parcel_import_batches", "shopify_stores"
  add_foreign_key "parcel_import_batches", "users"
  add_foreign_key "parcels", "orders"
  add_foreign_key "parcels", "shopify_stores"
  add_foreign_key "product_variants", "products"
  add_foreign_key "products", "shopify_stores"
  add_foreign_key "shipping_rate_card_rates", "shipping_rate_card_versions", column: "version_id"
  add_foreign_key "shipping_rate_card_versions", "companies"
  add_foreign_key "shipping_reminder_rules", "companies"
  add_foreign_key "shipping_reminder_settings", "companies"
  add_foreign_key "shipping_remote_area_rules", "shipping_remote_area_versions", column: "version_id"
  add_foreign_key "shipping_remote_area_versions", "companies"
  add_foreign_key "shipping_zone_postal_rules", "companies"
  add_foreign_key "shopify_stores", "companies"
  add_foreign_key "shopify_stores", "groups"
  add_foreign_key "shopify_stores", "users"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "tickets", "customers"
  add_foreign_key "tickets", "email_accounts"
  add_foreign_key "tickets", "orders"
end
