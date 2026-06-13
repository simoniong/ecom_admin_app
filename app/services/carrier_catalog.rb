class CarrierCatalog
  DEFAULT_PATH = Rails.root.join("config/data/17track_carriers.json")

  def self.default
    @default ||= new
  end

  def self.reset!
    @default = nil
  end

  def initialize(path: DEFAULT_PATH)
    @path = path
  end

  def all
    @all ||= load_entries
  end

  def valid?(code)
    index.key?(code.to_i)
  end

  def name_for(code)
    index[code.to_i]
  end

  private

  def index
    @index ||= all.each_with_object({}) { |c, h| h[c["code"].to_i] = c["name"] }
  end

  def load_entries
    return [] unless File.exist?(@path)

    JSON.parse(File.read(@path))
  rescue JSON::ParserError
    []
  end
end
