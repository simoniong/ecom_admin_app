Rails.application.routes.draw do
  devise_for :users, controllers: { sessions: "users/sessions" }

  # OmniAuth callbacks (outside locale scope — Google redirects to a fixed URL)
  get "auth/google_oauth2/callback", to: "oauth_callbacks#google_oauth2"
  get "auth/failure", to: "oauth_callbacks#failure"

  # Shopify OAuth (outside locale scope — Shopify redirects to a fixed URL)
  get "shopify/auth", to: "shopify_oauth#auth", as: :shopify_auth
  get "shopify/callback", to: "shopify_oauth#callback", as: :shopify_callback

  # Meta OAuth callbacks (outside locale scope — Meta redirects to a fixed URL)
  get "meta/auth", to: "meta_oauth#auth", as: :meta_auth
  get "meta/callback", to: "meta_oauth#callback", as: :meta_callback
  post "meta/select_accounts", to: "meta_oauth#select_accounts", as: :meta_select_accounts

  # Agent API
  namespace :api do
    namespace :v1 do
      resources :tickets, only: [ :index, :show ] do
        post :draft_reply, on: :member
      end
      resources :ad_campaigns, only: [ :index ]
    end
  end

  scope "(:locale)", locale: /en|zh-CN|zh-TW/ do
    authenticated :user do
      root "dashboard#show", as: :authenticated_root
    end

    resources :email_accounts, only: [ :index, :show, :destroy ]
    resources :shopify_stores, only: [ :index, :show, :update, :destroy ]
    resources :ad_accounts, only: [ :index, :show, :destroy ]
    resources :ad_campaigns, only: [ :index ]
    resources :campaign_display_templates, only: [ :create, :update, :destroy ]
    resources :tickets, only: [ :index, :show, :update ]
  end

  devise_scope :user do
    root "users/sessions#new"
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
