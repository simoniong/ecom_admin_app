Rails.application.routes.draw do
  devise_for :users, controllers: { sessions: "users/sessions" }

  scope "(:locale)", locale: /en|zh-CN|zh-TW/ do
    authenticated :user do
      root "dashboard#show", as: :authenticated_root
    end

    resources :email_accounts, only: [ :index ]
    resources :tickets, only: [ :index ]
  end

  devise_scope :user do
    root "users/sessions#new"
  end

  get "up" => "rails/health#show", as: :rails_health_check
end
