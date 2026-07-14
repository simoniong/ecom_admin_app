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

  SEQUENCE_HEADER   = "序号".freeze
  IDENTIFIER_HEADER = "订单编号".freeze
  GRAND_TOTAL_HEADER = "加单总运费（RMB)".freeze

  # A bill that omits GRAND_TOTAL_HEADER entirely (the "July shape") carries a
  # subtotal column instead, under one of two header spellings seen in the
  # wild. That subtotal excludes the 2-yuan handling fee that GRAND_TOTAL_HEADER
  # would otherwise have included — see #derive_cost!.
  SUBTOTAL_HEADERS = [ "总运费", "总运费（RMB)" ].freeze

  OPERATION_FEE_HEADER = "操作费".freeze

  REQUIRED_HEADERS = [ SEQUENCE_HEADER, IDENTIFIER_HEADER ].freeze

  # Applied per parcel only when the bill has no GRAND_TOTAL_HEADER column and
  # therefore no way to read a billed handling fee either. Money, so BigDecimal
  # — never a Float literal.
  DEFAULT_OPERATION_FEE_CNY = BigDecimal("2")

  MONEY_KEYS   = %i[cost_cny freight_cny registration_fee_cny tax_cny remote_area_fee_cny operation_fee_cny].freeze
  INTEGER_KEYS = %i[actual_weight_g billed_weight_g].freeze

  # A real bill's `last_row` can report far more rows than actually carry data
  # (Excel's own formatting-residue artefact inflates the sheet's declared
  # dimension into the millions on an otherwise 56-row file). Bailing out after
  # a long run of consecutive blank-序号 rows keeps that from turning into a
  # multi-minute crawl — legitimate bills never have anywhere near this many
  # consecutive blank rows before their footer.
  MAX_CONSECUTIVE_BLANK_ROWS = 1000

  def initialize(path)
    @path = path.to_s
  end

  def call
    sheet = Roo::Excelx.new(@path).sheet(0)
    header_row = sheet.row(1).map { |c| c.to_s.strip }

    missing = missing_headers(header_row)
    return { rows: [], errors: [ "缺少必要欄位：#{missing.join('、')}" ] } if missing.any?

    index = header_row.each_with_index.to_h
    rows = []
    errors = []

    each_data_row(sheet, index) do |raw, n|
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

  def missing_headers(header_row)
    missing = REQUIRED_HEADERS.reject { |h| header_row.include?(h) }
    has_cost_source = header_row.include?(GRAND_TOTAL_HEADER) ||
                       SUBTOTAL_HEADERS.any? { |h| header_row.include?(h) }
    missing << "#{GRAND_TOTAL_HEADER}（或 #{SUBTOTAL_HEADERS.join('/')}）" unless has_cost_source
    missing
  end

  # Footer total rows carry a value only in the last column and have no 序号,
  # which is how they're excluded. See MAX_CONSECUTIVE_BLANK_ROWS above for why
  # this also gives up early on a long run of blanks rather than trusting
  # sheet.last_row all the way to whatever Excel claims it is.
  def each_data_row(sheet, index)
    blank_run = 0
    (2..sheet.last_row).each do |n|
      raw = sheet.row(n)
      if raw[index[SEQUENCE_HEADER]].blank?
        blank_run += 1
        break if blank_run >= MAX_CONSECUTIVE_BLANK_ROWS
        next
      end
      blank_run = 0
      yield raw, n
    end
  end

  def extract(raw, index)
    attrs = COLUMN_MAP.each_with_object({}) do |(header, key), memo|
      pos = index[header]
      value = pos ? raw[pos] : nil
      memo[key] = cast(key, value)
    end
    derive_cost!(attrs, raw, index)
    attrs
  end

  # June-shaped bills carry GRAND_TOTAL_HEADER, which already includes the
  # 2-yuan handling fee — read as-is, nothing added, even on a row where that
  # cell happens to be blank (that's still a per-row "cost missing" error, not
  # a fallback). Only when the column itself is entirely absent (the
  # July shape) is the subtotal + operation fee used instead, and the applied
  # fee is written back into operation_fee_cny (so the report's fee breakdown
  # still shows it) with derived_operation_fee: true marking that it was
  # added, not billed.
  def derive_cost!(attrs, raw, index)
    return if index.key?(GRAND_TOTAL_HEADER)

    subtotal = subtotal_value(raw, index)
    return if subtotal.nil?

    fee = attrs[:operation_fee_cny].presence || DEFAULT_OPERATION_FEE_CNY
    attrs[:operation_fee_cny] = fee
    attrs[:cost_cny] = (subtotal + fee).round(2)
    attrs[:derived_operation_fee] = true
  end

  def subtotal_value(raw, index)
    header = SUBTOTAL_HEADERS.find { |h| index.key?(h) }
    return nil unless header

    to_money(raw[index[header]])
  end

  def cast(key, value)
    return nil if value.blank? && value != 0

    case key
    when :shipped_at   then value.is_a?(String) ? Time.zone.parse(value) : value
    when *MONEY_KEYS   then to_money(value)
    when *INTEGER_KEYS then value.to_i
    else value.to_s.strip.presence
    end
  rescue ArgumentError, TypeError
    nil
  end

  def to_money(value)
    return nil if value.blank? && value != 0

    BigDecimal(value.to_s).round(2)
  rescue ArgumentError, TypeError
    nil
  end

  # decimal(10,2) tops out at 99999999.99 — 8 integer digits — so anything at
  # or above 10**8 cannot be stored and would otherwise reach the DB as an
  # unhandled ActiveRecord::RangeError on confirm. A cell that parses to <= 0
  # (e.g. a stray tracking number pasted into this column) is equally not a
  # real cost and must be caught here, not after it has poisoned a rollup.
  MAX_COST_CNY = 10**8

  def validate(attrs, line)
    errors = []
    errors << "第 #{line} 列：订单编号 為空" if attrs[:identifier].blank?
    errors << "第 #{line} 列：#{GRAND_TOTAL_HEADER} 為空或非數字" if attrs[:cost_cny].blank?
    if attrs[:cost_cny].present? && (attrs[:cost_cny] <= 0 || attrs[:cost_cny] >= MAX_COST_CNY)
      errors << "第 #{line} 列：#{GRAND_TOTAL_HEADER} 數值超出範圍"
    end
    errors
  end
end
