FactoryBot.define do
  factory :email_workflow_step do
    email_workflow
    sequence(:position) { |n| n - 1 }
    step_type { "delay" }
    config { { "amount" => 1, "unit" => "days" } }

    trait :delay do
      step_type { "delay" }
      config { { "amount" => 1, "unit" => "days" } }
    end

    trait :send_email do
      step_type { "send_email" }
      config { { "instruction" => "Please draft a follow-up email about the shipping status." } }
    end
  end
end
