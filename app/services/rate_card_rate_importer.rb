class RateCardRateImporter
  def initialize(version:, text:)
    @version = version
    @text = text.to_s
  end

  def call
    rows, errors = parse
    return { count: 0, errors: errors } if errors.any?

    ShippingRateCardRate.transaction do
      @version.rates.delete_all
      rows.each { |attrs| @version.rates.create!(attrs) }
    end
    { count: rows.size, errors: [] }
  end

  private

  def parse
    rows = []
    errors = []
    @text.each_line.with_index(1) do |line, n|
      line = line.strip
      next if line.empty?
      fields = line.split(",").map(&:strip)
      if fields.size != 5
        errors << "Line #{n}: expected 'zone,min,max,per_kg,flat'"
        next
      end
      zone, min, max, per_kg, flat = fields
      nums = [ min, max, per_kg, flat ].map { |x| Float(x) rescue nil }
      if nums.any?(&:nil?)
        errors << "Line #{n}: non-numeric value"
        next
      end
      min_v, max_v, per_v, flat_v = nums
      if max_v <= min_v
        errors << "Line #{n}: max (#{max_v}) must be > min (#{min_v})"
        next
      end
      rows << {
        zone: zone.presence,
        weight_min_kg: min_v, weight_max_kg: max_v,
        per_kg_rate_cny: per_v, flat_fee_cny: flat_v
      }
    end
    errors << "No valid rows found" if rows.empty? && errors.empty?
    [ rows, errors ]
  end
end
