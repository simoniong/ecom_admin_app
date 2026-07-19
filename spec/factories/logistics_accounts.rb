FactoryBot.define do
  factory :logistics_account do
    company
    provider { "raydo" }
    username { "TEST" }
    password { "123456" }
    url1_base { "http://www.sz56t.com:8082" }
    url2_base { "http://www.sz56t.com:8089" }
  end
end
