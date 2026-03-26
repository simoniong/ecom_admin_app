class TimezoneResolver
  # Common country code → timezone mapping
  # For countries with multiple timezones, uses the most populated/common one
  COUNTRY_TIMEZONES = {
    "US" => "America/New_York",
    "CA" => "America/Toronto",
    "GB" => "Europe/London",
    "UK" => "Europe/London",
    "DE" => "Europe/Berlin",
    "FR" => "Europe/Paris",
    "IT" => "Europe/Rome",
    "ES" => "Europe/Madrid",
    "NL" => "Europe/Amsterdam",
    "AU" => "Australia/Sydney",
    "NZ" => "Pacific/Auckland",
    "JP" => "Asia/Tokyo",
    "KR" => "Asia/Seoul",
    "CN" => "Asia/Shanghai",
    "HK" => "Asia/Hong_Kong",
    "TW" => "Asia/Taipei",
    "SG" => "Asia/Singapore",
    "MY" => "Asia/Kuala_Lumpur",
    "TH" => "Asia/Bangkok",
    "VN" => "Asia/Ho_Chi_Minh",
    "PH" => "Asia/Manila",
    "ID" => "Asia/Jakarta",
    "IN" => "Asia/Kolkata",
    "AE" => "Asia/Dubai",
    "SA" => "Asia/Riyadh",
    "IL" => "Asia/Jerusalem",
    "TR" => "Europe/Istanbul",
    "RU" => "Europe/Moscow",
    "BR" => "America/Sao_Paulo",
    "MX" => "America/Mexico_City",
    "AR" => "America/Argentina/Buenos_Aires",
    "CL" => "America/Santiago",
    "CO" => "America/Bogota",
    "ZA" => "Africa/Johannesburg",
    "NG" => "Africa/Lagos",
    "EG" => "Africa/Cairo",
    "SE" => "Europe/Stockholm",
    "NO" => "Europe/Oslo",
    "DK" => "Europe/Copenhagen",
    "FI" => "Europe/Helsinki",
    "PL" => "Europe/Warsaw",
    "AT" => "Europe/Vienna",
    "CH" => "Europe/Zurich",
    "BE" => "Europe/Brussels",
    "PT" => "Europe/Lisbon",
    "IE" => "Europe/Dublin"
  }.freeze

  def self.resolve(country_code)
    return "UTC" if country_code.blank?
    COUNTRY_TIMEZONES[country_code.upcase] || "UTC"
  end
end
