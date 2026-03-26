Rails.application.routes.draw do
  devise_for :users, controllers: { sessions: "users/sessions" }

  # OmniAuth callbacks (outside locale scope — Google redirects to a fixed URL)
  get "auth/google_oauth2/callback", to: "oauth_callbacks#google_oauth2"
  get "auth/failure", to: "oauth_callbacks#failure"

  # Agent API
  namespace :api do
    namespace :v1 do
      resources :tickets, only: [ :index, :show ] do
        post :draft_reply, on: :member
      end
    end
  end

  scope "(:locale)", locale: /en|zh-CN|zh-TW/ do
    authenticated :user do
      root "dashboard#show", as: :authenticated_root
    end

    resources :email_accounts, only: [ :index, :show, :destroy ]
    resources :tickets, only: [ :index, :show, :update ]
  end

  devise_scope :user do
    root "users/sessions#new"
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
