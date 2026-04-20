class ShopifyStoresController < AdminController
  before_action :set_shopify_store, only: [ :show, :update, :destroy ]

  def index
    @shopify_stores = visible_shopify_stores.order(created_at: :desc)
  end

  def show
    @email_accounts = visible_email_accounts.order(created_at: :desc)
    @ad_accounts = visible_ad_accounts.order(created_at: :desc)
  end

  def update
    if params[:shopify_store].is_a?(ActionController::Parameters) && params[:shopify_store].key?(:group_id)
      return redirect_to(shopify_store_path(@shopify_store), alert: t("companies.no_permission")) unless current_membership&.owner?

      if @shopify_store.update(shopify_store_group_params)
        redirect_to shopify_store_path(@shopify_store), notice: t("shopify_stores.group_updated")
      else
        redirect_to shopify_store_path(@shopify_store), alert: @shopify_store.errors.full_messages.join(", ")
      end
      return
    end

    if params.key?(:email_account_ids)
      email_account_ids = Array(params[:email_account_ids]).select(&:present?)
      visible_email_accounts.where(shopify_store: @shopify_store).update_all(shopify_store_id: nil)
      visible_email_accounts.where(id: email_account_ids).update_all(shopify_store_id: @shopify_store.id) if email_account_ids.any?
    end

    if params.key?(:ad_account_ids)
      ad_account_ids = Array(params[:ad_account_ids]).select(&:present?)
      visible_ad_accounts.where(shopify_store: @shopify_store).update_all(shopify_store_id: nil)
      visible_ad_accounts.where(id: ad_account_ids).update_all(shopify_store_id: @shopify_store.id) if ad_account_ids.any?
    end

    redirect_to shopify_store_path(@shopify_store), notice: t("shopify_stores.updated")
  end

  def destroy
    ShopifyStoreDeletionService.new(@shopify_store).call
    redirect_to shopify_stores_path, notice: t("shopify_stores.disconnect_success")
  end

  private

  def set_shopify_store
    @shopify_store = visible_shopify_stores.find(params[:id])
  end

  def shopify_store_group_params
    params.require(:shopify_store).permit(:group_id)
  end
end
