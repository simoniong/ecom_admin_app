namespace :tracking do
  desc "Refresh the vendored 17Track carrier catalog snapshot"
  task refresh_carriers: :environment do
    url = "https://res.17track.net/asset/carrier/info/apicarrier.all.json"
    response = HTTParty.get(url, headers: { "User-Agent" => "ecom_admin_app" })
    raise "Carrier fetch failed (#{response.code})" unless response.success?

    entries = begin
      JSON.parse(response.body)
    rescue JSON::ParserError
      abort "17Track returned non-JSON response"
    end.map do |c|
      { "code" => c["key"], "name" => c["_name"]&.strip, "country" => c["_country_iso"]&.strip }
    end.select { |c| c["code"] && c["name"] }.sort_by { |c| c["name"].to_s }

    path = CarrierCatalog::DEFAULT_PATH
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.pretty_generate(entries))
    puts "Wrote #{entries.size} carriers to #{path}"
  end
end
