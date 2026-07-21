class Package < ApplicationRecord
  include AASM

  belongs_to :shopify_store
  belongs_to :order
  belongs_to :logistics_channel, optional: true
  has_many :package_items, inverse_of: :package, dependent: :destroy

  validates :number, presence: true, uniqueness: { scope: :shopify_store_id }
  validates :application_status, inclusion: { in: %w[none pending succeeded failed] }

  aasm column: :aasm_state do
    state :pending_review, initial: true
    state :pending_process
    state :applying_tracking
    state :pending_label
    state :shipped
    state :refunded
    state :held

    event :submit_review do
      transitions from: :pending_review, to: :pending_process
    end
    event :apply_tracking do
      transitions from: :pending_process, to: :applying_tracking
    end
    event :to_label do
      transitions from: :applying_tracking, to: :pending_label
    end
    event :ship do
      transitions from: :pending_label, to: :shipped
    end
    event :back_to_review do
      transitions from: :pending_process, to: :pending_review
    end
    event :back_to_process do
      transitions from: [ :applying_tracking, :pending_label ], to: :pending_process
    end
    event :hold do
      before { self.held_from = aasm_state }
      transitions from: [ :pending_review, :pending_process, :applying_tracking, :pending_label ], to: :held
    end
    event :unhold do
      transitions from: :held, to: :pending_review, guard: -> { held_from == "pending_review" }
      transitions from: :held, to: :pending_process, guard: -> { held_from == "pending_process" }
      transitions from: :held, to: :applying_tracking, guard: -> { held_from == "applying_tracking" }
      transitions from: :held, to: :pending_label, guard: -> { held_from == "pending_label" }
      # AASM's `after` runs post-save, so `self.held_from = nil` alone would only
      # mutate memory and leave the DB row stale. Guards above route on held_from,
      # so it must NOT be cleared before the transition — persist it directly here.
      after { update_column(:held_from, nil) }
    end
    event :refund do
      transitions from: [ :pending_review, :pending_process, :applying_tracking, :pending_label, :shipped, :held ], to: :refunded
    end
  end

  # e.g. "XMBDE2013094" — prefix + number zero-padded to at least 7 digits.
  def package_code
    "#{shopify_store.package_prefix}#{number.to_s.rjust(7, '0')}"
  end

  ADDRESS_REQUIRED = %w[name country_code address1 city].freeze

  def address_complete?
    ADDRESS_REQUIRED.all? { |k| shipping_address_snapshot[k].present? }
  end

  def logistics_assigned?
    logistics_channel_id.present?
  end

  # Customs is complete when every not-fully-refunded item has the 4 required
  # customs fields. Fully-refunded items are excluded (they won't ship).
  def customs_complete?
    shippable_items.all?(&:customs_complete?)
  end

  def ready_for_tracking?
    address_complete? && logistics_assigned? && customs_complete?
  end

  # Human-readable list of what's missing to advance to tracking application.
  def tracking_blockers
    blockers = []
    blockers << I18n.t("packages.blockers.address") unless address_complete?
    blockers << I18n.t("packages.blockers.logistics") unless logistics_assigned?
    shippable_items.reject(&:customs_complete?).each do |item|
      blockers << I18n.t("packages.blockers.customs", sku: item.sku)
    end
    blockers
  end

  # Items that still need to ship (fully-refunded items are excluded from
  # every readiness check — they won't be shipped).
  def shippable_items
    package_items.reject(&:fully_refunded?)
  end

  def order_cancelled?
    order.shopify_data["cancelled_at"].present? && order.financial_status != "refunded"
  end
end
