Rails.application.routes.draw do
  devise_for :users, controllers: { sessions: "users/sessions" }

  authenticated :user do
    root "dashboard#show", as: :authenticated_root
  end

  devise_scope :user do
    root "devise/sessions#new"
  end

  resources :email_accounts, only: [ :index ]
  resources :tickets, only: [ :index ]

  get "up" => "rails/health#show", as: :rails_health_check
end
