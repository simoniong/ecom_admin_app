require "roo"

# Parses a Dianxiaomi carrier-bill .xlsx into plain row hashes. Pure parsing —
# it never touches the database. Rows without a 序号 are skipped, which is how
# the file's footer SUM rows get excluded (see design doc §2).
class ParcelBillParser
  # Header text → row key. Exact strings as they appear in the export, including
  # the full-width parenthesis in 计费重（G) and 加单总运费（RMB).
  COLUMN_MAP = {
    "订单编号" => :identifier,
    "交易编号" => :order_name,
    "内部单号" => :internal_no,
    "货运单号" => :tracking_number,
    "发货时间" => :shipped_at,
    "物流渠道" => :service_channel,
    "分区" => :zone,
    "国家(中)" => :country,
    "重量" => :actual_weight_g,
    "计费重（G)" => :billed_weight_g,
    "运费总价" => :freight_cny,
    "挂号费" => :registration_fee_cny,
    "税金" => :tax_cny,
    "偏远费" => :remote_area_fee_cny,
    "操作费" => :operation_fee_cny,
    "加单总运费（RMB)" => :cost_cny
  }.freeze

  SEQUENCE_HEADER = "序号".freeze
  REQUIRED_HEADERS = [ SEQUENCE_HEADER, "订单编号", "加单总运费（RMB)" ].freeze

  MONEY_KEYS   = %i[cost_cny freight_cny registration_fee_cny tax_cny remote_area_fee_cny operation_fee_cny].freeze
  INTEGER_KEYS = %i[actual_weight_g billed_weight_g].freeze

  def initialize(path)
    @path = path.to_s
  end

  def call
    sheet = Roo::Excelx.new(@path).sheet(0)
    header_row = sheet.row(1).map { |c| c.to_s.strip }

    missing = REQUIRED_HEADERS.reject { |h| header_row.include?(h) }
    return { rows: [], errors: [ "缺少必要欄位：#{missing.join('、')}" ] } if missing.any?

    index = header_row.each_with_index.to_h
    rows = []
    errors = []

    (2..sheet.last_row).each do |n|
      raw = sheet.row(n)
      # Footer total rows carry a value only in the last column and have no 序号.
      next if raw[index[SEQUENCE_HEADER]].blank?

      attrs = extract(raw, index)
      row_errors = validate(attrs, n)
      if row_errors.any?
        errors.concat(row_errors)
      else
        rows << attrs
      end
    end

    { rows: rows, errors: errors }
  rescue Roo::Error, Zip::Error => e
    { rows: [], errors: [ "無法讀取檔案：#{e.message}" ] }
  end

  private

  def extract(raw, index)
    COLUMN_MAP.each_with_object({}) do |(header, key), attrs|
      pos = index[header]
      value = pos ? raw[pos] : nil
      attrs[key] = cast(key, value)
    end
  end

  def cast(key, value)
    return nil if value.blank? && value != 0

    case key
    when :shipped_at   then value.is_a?(String) ? Time.zone.parse(value) : value
    when *MONEY_KEYS   then BigDecimal(value.to_s).round(2)
    when *INTEGER_KEYS then value.to_i
    else value.to_s.strip.presence
    end
  rescue ArgumentError, TypeError
    nil
  end

  def validate(attrs, line)
    errors = []
    errors << "第 #{line} 列：订单编号 為空" if attrs[:identifier].blank?
    errors << "第 #{line} 列：加单总运费（RMB) 為空或非數字" if attrs[:cost_cny].blank?
    errors
  end
end
