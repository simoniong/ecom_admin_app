FactoryBot.define do
  factory :campaign_display_template do
    user
    company { user&.companies&.first || association(:company) }
    sequence(:name) { |n| "Template #{n}" }
    visible_columns { CampaignDisplayTemplate::ALL_COLUMNS }
    last_active_at { Time.current }
  end
end
