class Package < ApplicationRecord
  include AASM

  belongs_to :shopify_store
  belongs_to :order
  belongs_to :logistics_channel, optional: true
  has_many :package_items, dependent: :destroy

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
      after { self.held_from = nil }
    end
    event :refund do
      transitions from: [ :pending_review, :pending_process, :applying_tracking, :pending_label, :shipped, :held ], to: :refunded
    end
  end

  # e.g. "XMBDE2013094" — prefix + number zero-padded to at least 7 digits.
  def package_code
    "#{shopify_store.package_prefix}#{number.to_s.rjust(7, '0')}"
  end
end
