class AdCampaign < ApplicationRecord
  belongs_to :ad_account
  has_many :ad_campaign_daily_metrics, dependent: :destroy

  validates :campaign_id, presence: true, uniqueness: { scope: :ad_account_id }
  validates :status, presence: true, inclusion: { in: %w[active paused deleted] }

  scope :active, -> { where(status: "active") }

  def aggregated_metrics(date_range)
    metrics = ad_campaign_daily_metrics.where(date: date_range)
    totals = metrics.pick(
      Arel.sql("COALESCE(SUM(impressions), 0)"),
      Arel.sql("COALESCE(SUM(clicks), 0)"),
      Arel.sql("COALESCE(SUM(add_to_cart), 0)"),
      Arel.sql("COALESCE(SUM(checkout_initiated), 0)"),
      Arel.sql("COALESCE(SUM(purchases), 0)"),
      Arel.sql("COALESCE(SUM(spend), 0)"),
      Arel.sql("COALESCE(SUM(conversion_value), 0)")
    ) || [ 0, 0, 0, 0, 0, 0, 0 ]

    CampaignMetrics.new(*totals)
  end

  CampaignMetrics = Struct.new(
    :impressions, :clicks, :add_to_cart, :checkout_initiated,
    :purchases, :spend, :conversion_value
  ) do
    def ctr
      return 0 if impressions.zero?
      (clicks.to_f / impressions * 100).round(2)
    end

    def cpc
      return 0 if clicks.zero?
      (spend.to_f / clicks).round(2)
    end

    def cost_per_atc
      return 0 if add_to_cart.zero?
      (spend.to_f / add_to_cart).round(2)
    end

    def cost_per_checkout
      return 0 if checkout_initiated.zero?
      (spend.to_f / checkout_initiated).round(2)
    end

    def cost_per_purchase
      return 0 if purchases.zero?
      (spend.to_f / purchases).round(2)
    end

    def roas
      return 0 if spend.zero?
      (conversion_value.to_f / spend.to_f).round(2)
    end

    def atc_click_rate
      return 0 if clicks.zero?
      (add_to_cart.to_f / clicks * 100).round(2)
    end

    def checkout_atc_rate
      return 0 if add_to_cart.zero?
      (checkout_initiated.to_f / add_to_cart * 100).round(2)
    end

    def purchase_checkout_rate
      return 0 if checkout_initiated.zero?
      (purchases.to_f / checkout_initiated * 100).round(2)
    end

    def purchase_click_rate
      return 0 if clicks.zero?
      (purchases.to_f / clicks * 100).round(2)
    end
  end
end
