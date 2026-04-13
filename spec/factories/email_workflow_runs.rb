FactoryBot.define do
  factory :email_workflow_run do
    email_workflow
    order
    ticket
    status { "running" }
    started_at { Time.current }
  end
end
