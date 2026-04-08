class EmailAccount < ApplicationRecord
  belongs_to :user
  belongs_to :company
  belongs_to :shopify_store, optional: true
  has_many :tickets, dependent: :destroy

  encrypts :access_token, deterministic: false
  encrypts :refresh_token, deterministic: false

  validates :email, presence: true, uniqueness: { scope: :user_id }
  validates :google_uid, presence: true, uniqueness: true
  validates :access_token, presence: true
  validates :refresh_token, presence: true
end
