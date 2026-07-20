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

  # Intentionally a no-op. We cannot tell, at rollback time, which of the
  # memberships that now have both "shopify_stores" and "products" got
  # "products" from this backfill versus from an independent, later grant
  # (e.g. an admin explicitly adding the Products permission after deploy).
  # A previous version of this migration stripped "products" from every
  # membership that also had "shopify_stores", which would have destroyed
  # those independently-granted permissions on rollback. Since a granted
  # permission is harmless to leave in place, the safe rollback is to leave
  # the data untouched rather than guess and delete.
  def down
    # no-op — see comment above.
  end
end
