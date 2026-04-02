class Api::V1::AdCampaignsController < Api::BaseController
  def index
    campaigns = AdCampaign.includes(:ad_account)

    if params[:shopify_store_id].present?
      campaigns = campaigns.joins(:ad_account).where(ad_accounts: { shopify_store_id: params[:shopify_store_id] })
    end

    if params[:ad_account_id].present?
      campaigns = campaigns.where(ad_account_id: params[:ad_account_id])
    end

    if params[:status].present?
      campaigns = campaigns.where(status: params[:status])
    end

    from_date = params[:from_date].present? ? Date.parse(params[:from_date]) : 7.days.ago.to_date
    to_date = params[:to_date].present? ? Date.parse(params[:to_date]) : Date.current
    date_range = from_date..to_date

    render json: campaigns.order(:campaign_name).map { |c| campaign_json(c, date_range) }
  rescue Date::Error
    render json: { error: "Invalid date format" }, status: :bad_request
  end

  private

  def campaign_json(campaign, date_range)
    m = campaign.aggregated_metrics(date_range)

    {
      id: campaign.id,
      campaign_id: campaign.campaign_id,
      campaign_name: campaign.campaign_name,
      status: campaign.status,
      daily_budget: campaign.daily_budget.to_f,
      ad_account: {
        id: campaign.ad_account.id,
        account_id: campaign.ad_account.account_id,
        account_name: campaign.ad_account.account_name,
        platform: campaign.ad_account.platform,
        timezone: campaign.ad_account.timezone
      },
      metrics: {
        impressions: m.impressions,
        clicks: m.clicks,
        add_to_cart: m.add_to_cart,
        checkout_initiated: m.checkout_initiated,
        purchases: m.purchases,
        spend: m.spend.to_f,
        conversion_value: m.conversion_value.to_f,
        ctr: m.ctr,
        cpc: m.cpc,
        cost_per_atc: m.cost_per_atc,
        cost_per_checkout: m.cost_per_checkout,
        cost_per_purchase: m.cost_per_purchase,
        roas: m.roas,
        atc_click_rate: m.atc_click_rate,
        checkout_atc_rate: m.checkout_atc_rate,
        purchase_checkout_rate: m.purchase_checkout_rate,
        purchase_click_rate: m.purchase_click_rate
      },
      date_range: {
        from: date_range.first,
        to: date_range.last
      }
    }
  end
end
