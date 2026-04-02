FactoryBot.define do
  factory :campaign_display_template do
    user
    sequence(:name) { |n| "Template #{n}" }
    visible_columns { CampaignDisplayTemplate::ALL_COLUMNS }
    last_active_at { Time.current }
  end
end
