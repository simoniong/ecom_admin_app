class GroupsController < AdminController
  before_action :require_owner!
  before_action :set_group, only: [ :edit, :update, :destroy ]

  def index
    @groups = current_company.groups.order(:position, :created_at)
    @has_non_owner_memberships = current_company.memberships.member.exists?
    @unassigned_shopify_stores_count = current_company.shopify_stores.where(group_id: nil).count
    @unassigned_ad_accounts_count = current_company.ad_accounts.where(group_id: nil).count
    @unassigned_email_accounts_count = current_company.email_accounts.where(group_id: nil).count
  end

  def new
    @group = current_company.groups.build
  end

  def create
    if current_company.groups.none?
      result = Groups::CreateFirstGroup.new(current_company, group_params.to_h).call
      redirect_to groups_path, notice: t("groups.first_group_created",
                                         memberships: result.backfilled_membership_count,
                                         stores: result.backfilled_shopify_stores_count,
                                         ad_accounts: result.backfilled_ad_accounts_count,
                                         email_accounts: result.backfilled_email_accounts_count)
    else
      @group = current_company.groups.build(group_params)
      if @group.save
        redirect_to groups_path, notice: t("groups.created")
      else
        render :new, status: :unprocessable_entity
      end
    end
  rescue ActiveRecord::RecordInvalid => e
    @group = e.record
    render :new, status: :unprocessable_entity
  end

  def edit
  end

  def update
    if @group.update(group_params)
      redirect_to groups_path, notice: t("groups.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if group_has_dependents?(@group)
      redirect_to groups_path, alert: t("groups.cannot_destroy_non_empty")
      return
    end

    @group.destroy
    redirect_to groups_path, notice: t("groups.destroyed")
  end

  private

  def set_group
    @group = current_company.groups.find(params[:id])
  end

  def require_owner!
    unless current_membership&.owner?
      redirect_to authenticated_root_path, alert: t("companies.no_permission")
    end
  end

  def group_params
    params.require(:group).permit(:name, :description)
  end

  def group_has_dependents?(group)
    group.memberships.exists? ||
      group.shopify_stores.exists? ||
      group.ad_accounts.exists? ||
      group.email_accounts.exists? ||
      group.invitations.exists?
  end
end
