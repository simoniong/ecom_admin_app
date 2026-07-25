require "rails_helper"

RSpec.describe PackageSiblingIndex do
  let(:store)    { create(:shopify_store) }
  let(:customer) { create(:customer, shopify_store: store) }

  def make_order
    create(:order, customer: customer, shopify_store: store)
  end

  def make_package(order:, number:)
    create(:package, shopify_store: store, order: order, number: number, aasm_state: "pending_process")
  end

  # Counts real SQL, skipping the schema/transaction chatter that would make the
  # assertion depend on connection warm-up rather than on this class.
  def count_queries
    count = 0
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      count += 1 unless payload[:name].to_s.match?(/SCHEMA|TRANSACTION/)
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  it "omits a package whose order has only one box" do
    order = make_order
    package = make_package(order: order, number: 1)

    expect(described_class.new([ package ]).call).to eq({})
  end

  it "numbers a three-box order 1/3, 2/3, 3/3" do
    order = make_order
    a = make_package(order: order, number: 10)
    b = make_package(order: order, number: 11)
    c = make_package(order: order, number: 12)

    result = described_class.new([ a, b, c ]).call

    expect(result[a.id]).to eq([ 1, 3 ])
    expect(result[b.id]).to eq([ 2, 3 ])
    expect(result[c.id]).to eq([ 3, 3 ])
  end

  it "orders by box number, not by creation order" do
    order = make_order
    created_first = make_package(order: order, number: 20)
    created_second = make_package(order: order, number: 5)

    result = described_class.new([ created_first, created_second ]).call

    expect(result[created_second.id]).to eq([ 1, 2 ])
    expect(result[created_first.id]).to eq([ 2, 2 ])
  end

  it "numbers each order independently" do
    order_a = make_order
    order_b = make_order
    a1 = make_package(order: order_a, number: 1)
    a2 = make_package(order: order_a, number: 2)
    b1 = make_package(order: order_b, number: 3)
    b2 = make_package(order: order_b, number: 4)
    b3 = make_package(order: order_b, number: 5)

    result = described_class.new([ a1, a2, b1, b2, b3 ]).call

    expect(result[a2.id]).to eq([ 2, 2 ])
    expect(result[b3.id]).to eq([ 3, 3 ])
  end

  it "includes a sibling that was not passed in" do
    order = make_order
    passed = make_package(order: order, number: 1)
    make_package(order: order, number: 2)

    expect(described_class.new([ passed ]).call[passed.id]).to eq([ 1, 2 ])
  end

  it "returns an empty hash for no packages without querying" do
    expect(count_queries { expect(described_class.new([]).call).to eq({}) }).to eq(0)
  end

  # Guards the whole point of this class: it must not regress to a COUNT per row.
  it "resolves a whole page of packages in a single query" do
    orders = Array.new(5) { make_order }
    packages = orders.flat_map.with_index do |order, i|
      [ make_package(order: order, number: i * 10 + 1), make_package(order: order, number: i * 10 + 2) ]
    end

    expect(count_queries { described_class.new(packages).call }).to eq(1)
  end
end
