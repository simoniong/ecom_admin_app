class ParcelBillParser
  # Parses a 哆啦任意门 (Doragate) carrier bill — the carrier's own statement,
  # not a Dianxiaomi export. Shape differences from the Dianxiaomi bill:
  #
  # * Sheet 1 is a summary (汇总); the parcel rows are split across the
  #   remaining sheets (one per billing period, e.g. "1026", "1027-1030"), each
  #   with its own header row and a SUM footer row. Any sheet whose first row
  #   lacks the required headers is skipped, which is how the summary is left out.
  # * There is no Shopify order name. 客户订单号 is the ERP's package code, so
  #   the order is resolved afterwards — mainly by the waybill (运单号), which
  #   the ERP writes back to the Shopify fulfillment — see ParcelOrderResolver.
  #   This class stays pure parsing, like its parent.
  # * The bill's 操作费 (10/18/25 by channel and weight) is the carrier's own
  #   per-parcel fee — the counterpart of the Dianxiaomi bill's 挂号费 — so it is
  #   stored as registration_fee_cny. Our ¥2 handling fee is not on the bill at
  #   all and is added per parcel into operation_fee_cny, exactly as the July
  #   Dianxiaomi shape does (derived_operation_fee: true).
  #
  # Column mapping mirrors the Dianxiaomi one so both carriers read the same in
  # the report: 客户订单号 ↔ 订单编号 (identifier), 运单号 ↔ 内部单号
  # (internal_no), 派送单号 ↔ 货运单号 (tracking_number).
  class Doragate
    IDENTIFIER_HEADER = "客户订单号".freeze
    WAYBILL_HEADER    = "运单号".freeze
    TOTAL_HEADER      = "费用总金额".freeze
    REQUIRED_HEADERS  = [ IDENTIFIER_HEADER, WAYBILL_HEADER, TOTAL_HEADER ].freeze

    CNY = "人民币".freeze
    MAX_CONSECUTIVE_BLANK_ROWS = ParcelBillParser::MAX_CONSECUTIVE_BLANK_ROWS

    # True when any sheet of the workbook carries the Doragate header row.
    def self.match?(workbook)
      workbook.sheets.each_index.any? { |i| detail_sheet?(workbook.sheet(i)) }
    end

    def self.detail_sheet?(sheet)
      return false if sheet.first_row.nil?

      headers = sheet.row(1).map { |c| c.to_s.strip }
      REQUIRED_HEADERS.all? { |h| headers.include?(h) }
    end

    def initialize(workbook)
      @workbook = workbook
    end

    def call
      rows = []
      errors = []

      @workbook.sheets.each_with_index do |name, i|
        sheet = @workbook.sheet(i)
        next unless self.class.detail_sheet?(sheet)

        parse_sheet(sheet, name, rows, errors)
      end

      { rows: rows, errors: errors }
    end

    private

    def parse_sheet(sheet, name, rows, errors)
      index = sheet.row(1).map { |c| c.to_s.strip }.each_with_index.to_h
      blank_run = 0

      (2..sheet.last_row).each do |n|
        raw = sheet.row(n)
        # The SUM footer carries only 件数 and 费用总金额, so a blank 客户订单号
        # is how it is excluded — same role 序号 plays in the Dianxiaomi bill.
        if raw[index[IDENTIFIER_HEADER]].blank?
          blank_run += 1
          if blank_run >= MAX_CONSECUTIVE_BLANK_ROWS
            errors << "工作表「#{name}」第 #{n - MAX_CONSECUTIVE_BLANK_ROWS} 列之後偵測到連續 " \
                      "#{MAX_CONSECUTIVE_BLANK_ROWS} 列空白，解析在此中止；若帳單在此之後仍有資料，請檢查檔案。"
            break
          end
          next
        end
        blank_run = 0

        attrs = extract(raw, index)
        row_errors = validate(attrs, raw, index, name, n)
        row_errors.any? ? errors.concat(row_errors) : rows << attrs
      end
    end

    def extract(raw, index)
      cell = ->(header) { index.key?(header) ? raw[index[header]] : nil }

      waybill  = text(cell.("运单号"))
      delivery = text(cell.("派送单号"))
      total    = money(cell.(TOTAL_HEADER))
      fee      = ParcelBillParser::DEFAULT_OPERATION_FEE_CNY

      {
        identifier: text(cell.(IDENTIFIER_HEADER)),
        order_name: nil,
        package_code: text(cell.(IDENTIFIER_HEADER)),
        internal_no: waybill,
        tracking_number: delivery || waybill,
        shipped_at: date_time(cell.("计费时间")),
        service_channel: text(cell.("运输方式")),
        zone: nil,
        country: text(cell.("国家")),
        actual_weight_g: nil,
        billed_weight_g: grams(cell.("结算重量(KG)")),
        freight_cny: money(cell.("运费")),
        registration_fee_cny: money(cell.("操作费")),
        tax_cny: nil,
        remote_area_fee_cny: money(cell.("偏远费")),
        operation_fee_cny: fee,
        cost_cny: total && (total + fee).round(2),
        derived_operation_fee: true
      }
    end

    def validate(attrs, raw, index, sheet_name, line)
      where = "工作表「#{sheet_name}」第 #{line} 列"
      errors = []
      errors << "#{where}：#{WAYBILL_HEADER} 為空" if attrs[:internal_no].blank?
      if attrs[:cost_cny].blank?
        errors << "#{where}：#{TOTAL_HEADER} 為空或非數字"
      elsif attrs[:cost_cny] <= 0 || attrs[:cost_cny] >= ParcelBillParser::MAX_COST_CNY
        errors << "#{where}：#{TOTAL_HEADER} 數值超出範圍"
      end
      currency = index.key?("币种") ? raw[index["币种"]].to_s.strip : CNY
      errors << "#{where}：币种「#{currency}」不是人民币" unless currency.blank? || currency == CNY
      errors
    end

    def text(value)
      value.to_s.strip.presence
    end

    def money(value)
      return nil if value.blank? && value != 0

      BigDecimal(value.to_s).round(2)
    rescue ArgumentError, TypeError
      nil
    end

    def grams(value)
      kg = money_like(value)
      kg && (kg * 1000).round.to_i
    end

    def money_like(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # 计费时间 is a calendar date. Stored as midnight UTC on that date, matching
    # how the Dianxiaomi 发货时间 is stored as written (China wall-clock in a UTC
    # column) so the ship-date window in ParcelsController#shipped_window adds
    # up to the bill either way.
    def date_time(value)
      date =
        case value
        when Date then value
        when Time, DateTime then value.to_date
        when String then Date.parse(value)
        end
      date && Time.utc(date.year, date.month, date.day)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
