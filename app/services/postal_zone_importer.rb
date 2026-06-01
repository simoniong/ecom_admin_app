class PostalZoneImporter
  def initialize(company:, country:, text:)
    @company = company
    @country = country
    @text = text.to_s
  end

  # Serialize a country's rules back into the paste format (inverse of parse),
  # so the import textarea can be pre-filled for editing.
  def self.dump(country:, rules:)
    case country
    when "AU" then dump_au(rules)
    when "CA" then dump_ca(rules)
    else ""
    end
  end

  def call
    unless PostalNormalizer::SUPPORTED_COUNTRIES.include?(@country)
      return { count: 0, errors: [ "Unsupported country: #{@country}" ] }
    end
    rows, errors = parse
    return { count: 0, errors: errors } if errors.any?

    ts = Time.current
    ShippingZonePostalRule.transaction do
      @company.shipping_zone_postal_rules.where(country_code: @country).delete_all
      if rows.any?
        ShippingZonePostalRule.insert_all!(
          rows.map { |r| r.merge(company_id: @company.id, country_code: @country, created_at: ts, updated_at: ts) }
        )
      end
    end
    { count: rows.size, errors: [] }
  end

  private

  # Returns [rows, errors]. rows = [{zone:, postal_start:, postal_end:}, ...]
  def parse
    rows = []
    errors = []
    @text.each_line.with_index(1) do |line, n|
      line = line.strip
      next if line.empty?
      parsed = (@country == "AU" ? parse_au_line(line) : parse_ca_line(line))
      if parsed.is_a?(String)
        errors << "Line #{n}: #{parsed}"
      else
        rows.concat(parsed)
      end
    end
    errors << "No valid rows found" if rows.empty? && errors.empty?
    [ rows, errors ]
  end

  # "1: 1000-1935, 2000-2079, 2158" -> rows, or an error String
  def parse_au_line(line)
    zone, rest = line.split(":", 2)
    return "expected '<zone>: <ranges>'" if rest.nil? || zone.strip.empty?
    zone = zone.strip
    out = []
    rest.split(",").each do |tok|
      tok = tok.strip
      next if tok.empty?
      range = PostalNormalizer.range_for("AU", tok)
      return "bad postcode/range '#{tok}'" unless range
      out << { zone: zone, postal_start: range[0], postal_end: range[1] }
    end
    out.empty? ? "no ranges" : out
  end

  # "G0A4V0,1" -> rows, or an error String
  def parse_ca_line(line)
    token, zone = line.split(",", 2)
    return "expected '<postal>,<zone>'" if zone.nil? || zone.strip.empty? || token.to_s.strip.empty?
    range = PostalNormalizer.range_for("CA", token.strip)
    return "bad postal '#{token.strip}'" unless range
    [ { zone: zone.strip, postal_start: range[0], postal_end: range[1] } ]
  end

  def self.dump_au(rules)
    rules.group_by(&:zone).sort.map do |zone, zone_rules|
      ranges = zone_rules.sort_by(&:postal_start).map do |r|
        r.postal_start == r.postal_end ? r.postal_start : "#{r.postal_start}-#{r.postal_end}"
      end
      "#{zone}: #{ranges.join(', ')}"
    end.join("\n")
  end

  def self.dump_ca(rules)
    rules.sort_by(&:postal_start).map do |r|
      token = r.postal_start[3, 3] == "000" ? r.postal_start[0, 3] : r.postal_start
      "#{token},#{r.zone}"
    end.join("\n")
  end
  private_class_method :dump_au, :dump_ca
end
