module Groups
  class CreateFirstGroup
    Result = Struct.new(:group, :backfilled_membership_count, :backfilled_shopify_stores_count, :backfilled_ad_accounts_count, :backfilled_email_accounts_count, keyword_init: true)

    def initialize(company, attributes)
      @company = company
      @attributes = attributes
    end

    def call
      ActiveRecord::Base.transaction do
        group = @company.groups.create!(@attributes)

        membership_count = @company.memberships.member.where(group_id: nil).update_all(group_id: group.id)
        stores_count = @company.shopify_stores.where(group_id: nil).update_all(group_id: group.id)
        ads_count = @company.ad_accounts.where(group_id: nil).update_all(group_id: group.id)
        emails_count = @company.email_accounts.where(group_id: nil).update_all(group_id: group.id)

        Result.new(
          group: group,
          backfilled_membership_count: membership_count,
          backfilled_shopify_stores_count: stores_count,
          backfilled_ad_accounts_count: ads_count,
          backfilled_email_accounts_count: emails_count
        )
      end
    end
  end
end
