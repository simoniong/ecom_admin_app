# Provider-agnostic entry point for logistics/fulfillment operations.
# `FulfillmentService.for(account)` returns the adapter for that account's
# provider; the packing module talks to the adapter's common interface and
# never needs to know which carrier it is. Add a new carrier by writing a
# `FulfillmentService::<Provider>` adapter and registering it in `.for`.
module FulfillmentService
  class Error < StandardError; end
  class UnknownProvider < Error; end

  ADAPTERS = {
    "raydo" => "FulfillmentService::Raydo"
  }.freeze

  def self.for(account)
    klass = ADAPTERS[account.provider.to_s]
    raise UnknownProvider, "No fulfillment adapter for provider #{account.provider.inspect}" unless klass
    klass.constantize.new(account)
  end
end
