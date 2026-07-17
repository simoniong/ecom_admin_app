class RemoteAreaRuleImporter
  def initialize(version:, text:)
    @version = version
    @country = version.country_code
    @text = text.to_s
  end

  def call
    unless PostalNormalizer::SUPPORTED_COUNTRIES.include?(@country)
      return { count: 0, errors: [ "Unsupported country: #{@country}" ] }
    end
    rows, errors = parse
    return { count: 0, errors: errors } if errors.any?

    ts = Time.current
    ShippingRemoteAreaRule.transaction do
      @version.rules.delete_all
      ShippingRemoteAreaRule.insert_all!(
        rows.map { |r| r.merge(version_id: @version.id, created_at: ts, updated_at: ts) }
      ) if rows.any?
    end
    { count: rows.size, errors: [] }
  end

  private

  # Each line: "<code><TAB|,><area><TAB|,><price>". Returns [rows, errors] where
  # rows = [{postal_start:, postal_end:, surcharge_cny:, area_label:}, ...].
  def parse
    rows = []
    errors = []
    @text.each_line.with_index(1) do |line, n|
      line = line.strip
      next if line.empty?
      parsed = parse_line(line)
      parsed.is_a?(String) ? errors << "Line #{n}: #{parsed}" : rows.concat(parsed)
    end
    errors << "No valid rows found" if rows.empty? && errors.empty?
    [ rows, errors ]
  end

  def parse_line(line)
    parts = line.split(/[\t,]/).map(&:strip)
    return "expected 'code, area, price'" if parts.size < 3
    code, area, price = parts[0], parts[1], parts[2]
    range = PostalNormalizer.range_for(@country, code)
    return "bad postcode '#{code}'" unless range
    amount = begin
      BigDecimal(price, exception: false)
    rescue ArgumentError, TypeError
      nil
    end
    return "bad price '#{price}'" if amount.nil? || !amount.finite? || amount.negative?
    [ { postal_start: range[0], postal_end: range[1], surcharge_cny: amount, area_label: area.presence } ]
  end
end
