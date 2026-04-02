class ShopifyStoresController < AdminController
  before_action :set_shopify_store, only: [ :show, :update, :destroy ]

  def index
    @shopify_stores = current_user.shopify_stores.order(created_at: :desc)
  end

  def show
    @email_accounts = current_user.email_accounts.order(created_at: :desc)
    @ad_accounts = current_user.ad_accounts.order(created_at: :desc)
  end

  def update
    email_account_ids = Array(params[:email_account_ids]).select(&:present?)
    ad_account_ids = Array(params[:ad_account_ids]).select(&:present?)

    # Unlink all email accounts currently linked to this store
    current_user.email_accounts.where(shopify_store: @shopify_store).update_all(shopify_store_id: nil)

    # Link selected email accounts
    if email_account_ids.any?
      current_user.email_accounts.where(id: email_account_ids).update_all(shopify_store_id: @shopify_store.id)
    end

    # Unlink all ad accounts currently linked to this store
    current_user.ad_accounts.where(shopify_store: @shopify_store).update_all(shopify_store_id: nil)

    # Link selected ad accounts
    if ad_account_ids.any?
      current_user.ad_accounts.where(id: ad_account_ids).update_all(shopify_store_id: @shopify_store.id)
    end

    redirect_to shopify_store_path(@shopify_store), notice: t("shopify_stores.updated")
  end

  def destroy
    @shopify_store.destroy
    redirect_to shopify_stores_path, notice: t("shopify_stores.disconnect_success")
  end

  private

  def set_shopify_store
    @shopify_store = current_user.shopify_stores.find(params[:id])
  end
end
