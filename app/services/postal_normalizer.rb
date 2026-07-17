class PostalNormalizer
  SUPPORTED_COUNTRIES = %w[AU CA GB].freeze

  # Normalize an order's raw postal into a fixed-width lookup key, or nil.
  def self.normalize(country, raw)
    return nil if raw.blank?
    case country
    when "AU" then normalize_au(raw)
    when "CA" then normalize_ca(raw)
    when "GB" then normalize_gb(raw)
    end
  end

  # Expand one import token into [start_key, end_key], or nil if malformed.
  def self.range_for(country, token)
    case country
    when "AU" then range_au(token)
    when "CA" then range_ca(token)
    when "GB" then range_gb(token)
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

  # UK outward code -> "<LETTERS><2-digit district>". Strips whitespace and the
  # inward code (always digit + 2 letters, e.g. "1AA") so a full postcode with
  # or without a space parses the same, then fully anchors the outward pattern:
  # leading letters (1–2) + district digits (1–2) + an optional trailing letter
  # (e.g. "EC1A"). Zero-pads the digits to 2 so BT1 ("BT01") and BT10 ("BT10")
  # stay distinct and comparable for range matching. The full \z anchor rejects
  # junk input ("BT1@", "AB35XYZ") instead of matching a leading prefix.
  def self.normalize_gb(raw)
    s = raw.to_s.strip.upcase.gsub(/\s+/, "")
    s = s.sub(/\d[A-Z]{2}\z/, "") # drop inward code if a full postcode was given
    m = s.match(/\A([A-Z]{1,2})(\d{1,2})[A-Z]?\z/)
    return nil unless m
    "#{m[1]}#{m[2].rjust(2, '0')}"
  end

  # Import token -> [start_key, end_key]:
  #   "AB35"     -> ["AB35","AB35"]      (single district)
  #   "IV"       -> ["IV00","IV99"]      (whole letter area)
  #   "KA27-28"  -> ["KA27","KA28"]      (district range, same letters)
  def self.range_gb(token)
    t = token.to_s.strip.upcase
    return nil if t.empty?

    if (m = t.match(/\A([A-Z]{1,2})(\d{1,2})-(\d{1,2})\z/))
      letters, a, b = m[1], m[2].rjust(2, "0"), m[3].rjust(2, "0")
      return nil if b < a
      return [ "#{letters}#{a}", "#{letters}#{b}" ]
    end

    if t.match?(/\A[A-Z]{1,2}\z/) # bare letter area
      return [ "#{t}00", "#{t}99" ]
    end

    v = normalize_gb(t) # single outward code
    v && [ v, v ]
  end

  private_class_method :normalize_au, :range_au, :normalize_ca, :range_ca,
                       :normalize_gb, :range_gb
end
