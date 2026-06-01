class PostalNormalizer
  # Normalize an order's raw postal into a fixed-width lookup key, or nil.
  def self.normalize(country, raw)
    return nil if raw.blank?
    case country
    when "AU" then normalize_au(raw)
    when "CA" then normalize_ca(raw)
    end
  end

  # Expand one import token into [start_key, end_key], or nil if malformed.
  def self.range_for(country, token)
    case country
    when "AU" then range_au(token)
    when "CA" then range_ca(token)
    end
  end

  def self.normalize_au(raw)
    s = raw.to_s.gsub(/\s/, "")
    return nil unless s.match?(/\A\d{1,4}\z/)
    s.rjust(4, "0")
  end

  def self.range_au(token)
    if token.to_s.include?("-")
      a, b = token.to_s.split("-", 2).map { |x| normalize_au(x) }
      (a && b && b >= a) ? [ a, b ] : nil
    else
      v = normalize_au(token)
      v && [ v, v ]
    end
  end

  def self.normalize_ca(raw)
    s = raw.to_s.upcase.gsub(/[^A-Z0-9]/, "")
    case s.length
    when 6 then s
    when 3 then "#{s}000"
    end
  end

  def self.range_ca(token)
    s = token.to_s.upcase.gsub(/[^A-Z0-9]/, "")
    case s.length
    when 3 then [ "#{s}000", "#{s}ZZZ" ]
    when 6 then [ s, "#{s[0, 3]}ZZZ" ]
    end
  end

  private_class_method :normalize_au, :range_au, :normalize_ca, :range_ca
end
