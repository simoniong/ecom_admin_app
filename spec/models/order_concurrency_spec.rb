require "rails_helper"

# use_transactional_tests must be off here: the default transactional-fixture
# wrapper keeps everything the main thread creates inside one uncommitted
# transaction on the main connection, invisible to any other real DB
# connection. A genuine two-connection race can only be reproduced against
# data that is actually committed, so this file commits for real and cleans
# up its own rows in an `after` hook instead of relying on rollback.
RSpec.describe "Order actual_shipping_cost under concurrent parcel writes", type: :model do
  self.use_transactional_tests = false

  let(:user)     { create(:user) }
  let(:company)  { user.companies.first }
  let(:store)    { create(:shopify_store, user: user, company: company, cost_fx_rate: 7.2) }
  let(:customer) { create(:customer, shopify_store: store) }

  after do
    Parcel.where(shopify_store: store).delete_all
    company.destroy
    user.destroy
  end

  it "sums both parcels' cost instead of losing one to a last-writer-wins race" do
    order = create(:order, customer: customer, shopify_store: store, estimated_shipping_cost: 10)
    ready   = Queue.new
    release = Queue.new

    make_writer = lambda do |identifier, cost|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Order.transaction do
            Parcel.insert_all!([ {
              id: SecureRandom.uuid, shopify_store_id: store.id, order_id: order.id,
              identifier: identifier, cost_cny: cost * 7.2, cost_amount: cost,
              created_at: Time.current, updated_at: Time.current
            } ])
            # Signal that this connection's parcel row exists but is not yet
            # committed, then block until the other connection has done the
            # same — forcing both refreshes to run while neither transaction
            # can see the other's row unless it waits for a lock.
            ready << true
            release.pop
            Order.find(order.id).refresh_actual_shipping_cost!
          end
        end
      end
    end

    t1 = make_writer.call("RACE-A", 10)
    t2 = make_writer.call("RACE-B", 5)

    2.times { ready.pop }
    2.times { release << true }
    [ t1, t2 ].each(&:join)

    expect(order.reload.actual_shipping_cost).to eq(15)
  end

  # Parcel#refresh_order_rollups can touch TWO orders when a parcel moves
  # (the old one and the new one). If two parcels move between the same two
  # orders in opposite directions at the same moment, each transaction needs
  # both orders' locks — and if the two transactions requested them in
  # opposite sequence (mover A→B locking [B, A], mover B→A locking [A, B]),
  # each could hold the first lock the other is waiting for: a deadlock, not
  # just a slowdown. refresh_order_rollups sorts the id list before locking so
  # both movers always request the same order regardless of which direction
  # they're going. Run several times since a deadlock from unsorted ids would
  # depend on the two threads' exact timing, not fire on every iteration.
  it "does not deadlock when two parcels move between the same two orders in opposite directions" do
    order_a = create(:order, customer: customer, shopify_store: store, name: "CONC-A")
    order_b = create(:order, customer: customer, shopify_store: store, name: "CONC-B")

    10.times do |i|
      parcel_a_to_b = create(:parcel, shopify_store: store, order: order_a, identifier: "MOVE-A2B-#{i}", cost_amount: 10)
      parcel_b_to_a = create(:parcel, shopify_store: store, order: order_b, identifier: "MOVE-B2A-#{i}", cost_amount: 20)

      errors = []
      threads = [
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection { parcel_a_to_b.update!(order: order_b) }
        rescue => e
          errors << e
        end,
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection { parcel_b_to_a.update!(order: order_a) }
        rescue => e
          errors << e
        end
      ]
      threads.each(&:join)

      expect(errors.map(&:message)).to eq([])

      # Each iteration adds one more 20-cost parcel to order_a (moved in from
      # order_b) and one more 10-cost parcel to order_b (moved in from
      # order_a), on top of every earlier iteration's already-moved parcels.
      expect(order_a.reload.actual_shipping_cost).to eq(20 * (i + 1))
      expect(order_b.reload.actual_shipping_cost).to eq(10 * (i + 1))
    end
  end
end
