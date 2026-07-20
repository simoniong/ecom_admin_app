class BackfillProductsPermission < ActiveRecord::Migration[8.1]
  # The Products page used to be gated behind the "shopify_stores" permission.
  # This branch splits it into its own "products" permission
  # (see app/controllers/admin_controller.rb PERMISSION_KEY_MAP and
  # Membership::AVAILABLE_PERMISSIONS). Without this backfill, every existing
  # non-owner member who currently holds only "shopify_stores" would silently
  # lose access to the Products page on deploy (owners bypass permission
  # checks entirely, so they are unaffected either way).
  #
  # Implemented as raw SQL (not via the Membership model) so it is immune to
  # any current or future model validations/callbacks on Membership — this is
  # a pure data backfill on a jsonb column, not a domain write.
  def up
    execute <<~SQL
      UPDATE memberships
      SET permissions = permissions || '["products"]'::jsonb
      WHERE permissions @> '["shopify_stores"]'::jsonb
        AND NOT permissions @> '["products"]'::jsonb
    SQL
  end

  # Best-effort reverse: remove "products" only from memberships that still
  # have "shopify_stores" (i.e. rows this migration would have touched).
  # Memberships where "products" was granted independently of this backfill
  # (not paired with "shopify_stores") are intentionally left untouched.
  def down
    execute <<~SQL
      UPDATE memberships
      SET permissions = (
        SELECT COALESCE(jsonb_agg(perm), '[]'::jsonb)
        FROM jsonb_array_elements(permissions) AS perm
        WHERE perm <> '"products"'::jsonb
      )
      WHERE permissions @> '["shopify_stores"]'::jsonb
        AND permissions @> '["products"]'::jsonb
    SQL
  end
end
