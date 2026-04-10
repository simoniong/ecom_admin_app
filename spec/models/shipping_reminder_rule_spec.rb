require "rails_helper"

RSpec.describe ShippingReminderRule, type: :model do
  let(:company) { create(:company) }

  describe "validations" do
    it "is valid with valid attributes" do
      rule = build(:shipping_reminder_rule, company: company)
      expect(rule).to be_valid
    end

    it "validates rule_type presence" do
      rule = build(:shipping_reminder_rule, company: company, rule_type: nil)
      expect(rule).not_to be_valid
      expect(rule.errors[:rule_type]).to be_present
    end

    it "validates rule_type inclusion" do
      rule = build(:shipping_reminder_rule, company: company, rule_type: "invalid")
      expect(rule).not_to be_valid
    end

    it "validates uniqueness of rule_type per company" do
      create(:shipping_reminder_rule, company: company, rule_type: "not_delivered")
      duplicate = build(:shipping_reminder_rule, company: company, rule_type: "not_delivered")
      expect(duplicate).not_to be_valid
    end

    it "allows same rule_type for different companies" do
      create(:shipping_reminder_rule, company: company, rule_type: "not_delivered")
      other = create(:company)
      rule = build(:shipping_reminder_rule, company: other, rule_type: "not_delivered")
      expect(rule).to be_valid
    end

    it "validates country_thresholds structure" do
      rule = build(:shipping_reminder_rule, company: company, country_thresholds: [ { "invalid" => true } ])
      expect(rule).not_to be_valid
      expect(rule.errors[:country_thresholds]).to be_present
    end

    it "validates days must be positive" do
      rule = build(:shipping_reminder_rule, company: company, country_thresholds: [ { "country" => "US", "days" => 0 } ])
      expect(rule).not_to be_valid
    end

    it "allows tracking_stopped thresholds without days" do
      rule = build(:shipping_reminder_rule, company: company, rule_type: "tracking_stopped",
                   country_thresholds: [ { "country" => "US" } ])
      expect(rule).to be_valid
    end

    it "accepts empty country_thresholds" do
      rule = build(:shipping_reminder_rule, company: company, country_thresholds: [])
      expect(rule).to be_valid
    end
  end

  describe "#parsed_thresholds" do
    it "returns symbolized hashes" do
      rule = build(:shipping_reminder_rule, country_thresholds: [ { "country" => "US", "days" => 14 } ])
      expect(rule.parsed_thresholds).to eq([ { country: "US", days: 14 } ])
    end
  end

  describe ".enabled" do
    it "returns only enabled rules" do
      enabled = create(:shipping_reminder_rule, company: company, rule_type: "not_delivered", enabled: true)
      create(:shipping_reminder_rule, company: company, rule_type: "without_updates", enabled: false)
      expect(described_class.enabled).to eq([ enabled ])
    end
  end

  describe "#matching_fulfillments" do
    let(:store) { create(:shopify_store, company: company) }
    let(:order) { create(:order, shopify_store: store) }

    context "not_delivered rule" do
      let(:rule) do
        create(:shipping_reminder_rule, company: company, rule_type: "not_delivered",
               country_thresholds: [ { "country" => "US", "days" => 14 } ])
      end

      it "returns fulfillments shipped over X days ago and not delivered" do
        match = create(:fulfillment, order: order, tracking_number: "T1",
                       destination_country: "US", shipped_at: 20.days.ago,
                       tracking_status: "InTransit")
        # Delivered — should not match
        create(:fulfillment, order: order, tracking_number: "T2",
               destination_country: "US", shipped_at: 20.days.ago,
               tracking_status: "Delivered")
        # Too recent — should not match
        create(:fulfillment, order: order, tracking_number: "T3",
               destination_country: "US", shipped_at: 5.days.ago,
               tracking_status: "InTransit")
        # Wrong country — should not match
        create(:fulfillment, order: order, tracking_number: "T4",
               destination_country: "CA", shipped_at: 20.days.ago,
               tracking_status: "InTransit")

        results = rule.matching_fulfillments([ store.id ])
        expect(results).to eq([ match ])
      end
    end

    context "without_updates rule" do
      let(:rule) do
        create(:shipping_reminder_rule, company: company, rule_type: "without_updates",
               country_thresholds: [ { "country" => "US", "days" => 7 } ])
      end

      it "returns non-terminal fulfillments with stale last_event_at" do
        match = create(:fulfillment, order: order, tracking_number: "T1",
                       destination_country: "US", last_event_at: 10.days.ago,
                       tracking_status: "InTransit")
        # Terminal status — should not match
        create(:fulfillment, order: order, tracking_number: "T2",
               destination_country: "US", last_event_at: 10.days.ago,
               tracking_status: "Delivered")
        # Recent event — should not match
        create(:fulfillment, order: order, tracking_number: "T3",
               destination_country: "US", last_event_at: 2.days.ago,
               tracking_status: "InTransit")

        results = rule.matching_fulfillments([ store.id ])
        expect(results).to eq([ match ])
      end
    end

    context "ready_for_pickup rule" do
      let(:rule) do
        create(:shipping_reminder_rule, company: company, rule_type: "ready_for_pickup",
               country_thresholds: [ { "country" => "US", "days" => 3 } ])
      end

      it "returns AvailableForPickup fulfillments waiting over X days" do
        match = create(:fulfillment, order: order, tracking_number: "T1",
                       destination_country: "US", last_event_at: 5.days.ago,
                       tracking_status: "AvailableForPickup")
        # Different status — should not match
        create(:fulfillment, order: order, tracking_number: "T2",
               destination_country: "US", last_event_at: 5.days.ago,
               tracking_status: "InTransit")

        results = rule.matching_fulfillments([ store.id ])
        expect(results).to eq([ match ])
      end
    end

    context "tracking_stopped rule" do
      let(:rule) do
        create(:shipping_reminder_rule, company: company, rule_type: "tracking_stopped",
               country_thresholds: [ { "country" => "US" } ])
      end

      it "returns fulfillments with Exception or Expired status" do
        match_exception = create(:fulfillment, order: order, tracking_number: "T1",
                                 destination_country: "US",
                                 tracking_status: "Exception")
        match_expired = create(:fulfillment, order: order, tracking_number: "T2",
                               destination_country: "US",
                               tracking_status: "Expired")
        # InTransit — should not match
        create(:fulfillment, order: order, tracking_number: "T3",
               destination_country: "US",
               tracking_status: "InTransit")
        # Wrong country — should not match
        create(:fulfillment, order: order, tracking_number: "T4",
               destination_country: "CA",
               tracking_status: "Exception")

        results = rule.matching_fulfillments([ store.id ])
        expect(results).to contain_exactly(match_exception, match_expired)
      end
    end
  end
end
