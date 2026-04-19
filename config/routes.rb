Rails.application.routes.draw do
  devise_for :users, controllers: { sessions: "users/sessions", passwords: "users/passwords" }

  # OmniAuth callbacks (outside locale scope — Google redirects to a fixed URL)
  get "auth/google_oauth2/callback", to: "oauth_callbacks#google_oauth2"
  get "auth/failure", to: "oauth_callbacks#failure"

  # Shopify OAuth (outside locale scope — Shopify redirects to a fixed URL)
  get "shopify/auth", to: "shopify_oauth#auth", as: :shopify_auth
  get "shopify/callback", to: "shopify_oauth#callback", as: :shopify_callback

  # Shopify Webhooks (outside locale scope, no auth required — HMAC verified)
  post "shopify/webhooks", to: "shopify_webhooks#receive"

  # 17Track Webhooks (outside locale scope, token verified)
  post "tracking/webhooks", to: "tracking_webhooks#receive"

  # Meta OAuth callbacks (outside locale scope — Meta redirects to a fixed URL)
  get "meta/auth", to: "meta_oauth#auth", as: :meta_auth
  get "meta/callback", to: "meta_oauth#callback", as: :meta_callback
  post "meta/select_accounts", to: "meta_oauth#select_accounts", as: :meta_select_accounts

  # Invitation accept (outside locale scope — token-based URLs, no auth required)
  get "invitations/:token", to: "invitation_acceptances#show", as: :accept_invitation
  post "invitations/:token/accept", to: "invitation_acceptances#accept", as: :accept_invitation_confirm

  # Agent API
  namespace :api do
    namespace :v1 do
      resources :tickets, only: [ :index, :show ] do
        get :count, on: :collection
        post :draft_reply, on: :member
        patch :draft_reply, on: :member
      end
      resources :ad_campaigns, only: [ :index ]
    end
  end

  scope "(:locale)", locale: /en|zh-CN|zh-TW/ do
    authenticated :user do
      root "dashboard#show", as: :authenticated_root
    end

    resource :profile, only: [ :edit, :update ]
    resource :company, only: [ :edit, :update ]
    patch "company/tracking", to: "companies#update_tracking", as: :tracking_company
    patch "switch_company/:id", to: "company_sessions#update", as: :switch_company
    resources :invitations, only: [ :index, :create, :destroy ]
    resources :memberships, only: [ :edit, :update, :destroy ]
    resources :groups, except: [ :show ]

    resources :email_accounts, only: [ :index, :show, :update, :destroy ]
    post "email_oauth/start", to: "email_oauth#start", as: :email_oauth_start
    resources :shopify_stores, only: [ :index, :show, :update, :destroy ] do
      resources :email_workflows, only: [ :index, :new, :create, :edit, :update, :destroy ] do
        resources :email_workflow_steps, only: [ :create, :update, :destroy ] do
          post :move, on: :member
        end
      end
    end
    resources :ad_accounts, only: [ :index, :show, :update, :destroy ]
    resources :ad_campaigns, only: [ :index ] do
      post :sync, on: :collection
    end
    resources :campaign_display_templates, only: [ :create, :update, :destroy ]
    resources :orders, only: [ :index ] do
      post :sync, on: :collection
    end
    resources :shipments, only: [ :index, :show ] do
      post :sync, on: :collection
      post :bulk_archive, on: :collection
      post :bulk_unarchive, on: :collection
      post :bulk_add_tags, on: :collection
      post :bulk_remove_tags, on: :collection
      post :bulk_export, on: :collection
      get :available_tags, on: :collection
      post :archive, on: :member
      post :unarchive, on: :member
      post :add_tags, on: :member
      delete :remove_tag, on: :member
    end
    resources :tickets, only: [ :index, :show, :update ] do
      get :search_customers, on: :member
      patch :link_customer, on: :member
      post :instruct_agent, on: :member
    end
    resources :shipping_reminder_rules, only: [ :index, :create, :update ]
    resource :shipping_reminder_setting, only: [ :update ] do
      patch :toggle, on: :member
    end
  end

  devise_scope :user do
    root "users/sessions#new"
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
