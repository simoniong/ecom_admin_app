class BackfillCompaniesForExistingUsers < ActiveRecord::Migration[8.1]
  def up
    # Create one company per user deterministically by iterating through users.
    # This avoids nondeterministic joins when two users share the same email local-part.
    execute <<~SQL
      DO $$
      DECLARE
        u RECORD;
        new_company_id UUID;
      BEGIN
        FOR u IN SELECT id, email FROM users LOOP
          INSERT INTO companies (id, name, created_at, updated_at)
          VALUES (gen_random_uuid(), split_part(u.email, '@', 1) || '''s Company', NOW(), NOW())
          RETURNING id INTO new_company_id;

          INSERT INTO memberships (id, company_id, user_id, role, permissions, created_at, updated_at)
          VALUES (gen_random_uuid(), new_company_id, u.id, 1, '[]'::jsonb, NOW(), NOW());
        END LOOP;
      END $$;
    SQL

    execute <<~SQL
      UPDATE shopify_stores SET company_id = m.company_id
      FROM memberships m WHERE m.user_id = shopify_stores.user_id;
    SQL

    execute <<~SQL
      UPDATE ad_accounts SET company_id = m.company_id
      FROM memberships m WHERE m.user_id = ad_accounts.user_id;
    SQL

    execute <<~SQL
      UPDATE email_accounts SET company_id = m.company_id
      FROM memberships m WHERE m.user_id = email_accounts.user_id;
    SQL

    execute <<~SQL
      UPDATE campaign_display_templates SET company_id = m.company_id
      FROM memberships m WHERE m.user_id = campaign_display_templates.user_id;
    SQL
  end

  def down
    execute "DELETE FROM memberships"
    execute "DELETE FROM companies"
    execute "UPDATE shopify_stores SET company_id = NULL"
    execute "UPDATE ad_accounts SET company_id = NULL"
    execute "UPDATE email_accounts SET company_id = NULL"
    execute "UPDATE campaign_display_templates SET company_id = NULL"
  end
end
