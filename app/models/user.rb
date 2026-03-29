class User < ApplicationRecord
  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable, :recoverable, :rememberable,
         :validatable, :lockable

  has_many :email_accounts, dependent: :destroy
  has_many :shopify_stores, dependent: :destroy
  has_many :tickets, through: :email_accounts
end
