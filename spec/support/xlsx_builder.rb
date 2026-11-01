require "axlsx"

# Builds a carrier-bill .xlsx in a temp file, mirroring the real Dianxiaomi
# export layout (see the 2026-07-14 design doc §2). Returns the file path.
module XlsxBuilder
  HEADERS = [
    "序号", "发货时间", "订单编号", "交易编号", "内部单号", "货运单号",
    "物流渠道", "分区", "国家(中)", "重量", "店铺名", "订单状态", "店长", "平台",
    "计费重（G)", "运费单价/g", "运费总价", "挂号费", "税金", "偏远费",
    "总运费", "操作费", "加单总运费（RMB)"
  ].freeze

  # A representative row. Overrides are merged by header name.
  def self.row(seq:, identifier:, order_name:, cost: 239.732, **over)
    defaults = {
      "序号" => seq,
      "发货时间" => Time.utc(2026, 6, 1, 21, 48, 26),
      "订单编号" => identifier,
      "交易编号" => order_name,
      "内部单号" => "DOR0201415428CN",
      "货运单号" => "SPXORH011122606010001237",
      "物流渠道" => "美国标准（A带电）",
      "分区" => nil,
      "国家(中)" => "美国",
      "重量" => 2423,
      "店铺名" => "CSFD-STORE1",
      "订单状态" => "已发货",
      "店长" => "CSFD",
      "平台" => "Other",
      "计费重（G)" => 2421,
      "运费单价/g" => 0.092,
      "运费总价" => 222.732,
      "挂号费" => 15,
      "税金" => 0,
      "偏远费" => 0,
      "总运费" => 237.732,
      "操作费" => 2,
      "加单总运费（RMB)" => cost
    }
    defaults.merge(over.transform_keys(&:to_s))
  end

  # rows: array of hashes from .row; totals: array of numbers appended as
  # header-less total rows (序号 blank) to mimic the real file's SUM footer.
  def self.build(rows:, totals: [ 58_578.977 ])
    build_with_headers(HEADERS, rows: rows, totals: totals, sheet_name: "6月")
  end

  # The July-shaped bill: no 操作费 or 加单总运费（RMB) columns at all, and its
  # subtotal column is spelled with the RMB suffix (总运费（RMB)) rather than
  # bare 总运费. Its subtotal excludes the 2-yuan handling fee that the June
  # shape's 加单总运费（RMB) already includes — see ParcelBillParser#derive_cost!.
  JULY_HEADERS = (HEADERS - [ "操作费", "加单总运费（RMB)", "总运费" ] + [ "总运费（RMB)" ]).freeze

  # A representative July-shaped row. Overrides are merged by header name, same
  # as .row. `subtotal` is 总运费（RMB) — it does NOT include the handling fee.
  def self.july_row(seq:, identifier:, order_name:, subtotal: 122.732, **over)
    defaults = {
      "序号" => seq,
      "发货时间" => Time.utc(2026, 7, 1, 21, 48, 26),
      "订单编号" => identifier,
      "交易编号" => order_name,
      "内部单号" => "DOR0201415428CN",
      "货运单号" => "SPXORH011122607010001237",
      "物流渠道" => "美国标准（A带电）",
      "分区" => nil,
      "国家(中)" => "美国",
      "重量" => 2423,
      "店铺名" => "CSFD-STORE1",
      "订单状态" => "已发货",
      "店长" => "CSFD",
      "平台" => "Other",
      "计费重（G)" => 2421,
      "运费单价/g" => 0.092,
      "运费总价" => 107.732,
      "挂号费" => 15,
      "税金" => 0,
      "偏远费" => 0,
      "总运费（RMB)" => subtotal
    }
    defaults.merge(over.transform_keys(&:to_s))
  end

  # rows: array of hashes from .july_row. The real July bill has no footer
  # total rows, so totals defaults to none here (unlike .build).
  def self.build_july(rows:, totals: [])
    build_with_headers(JULY_HEADERS, rows: rows, totals: totals, sheet_name: "7月")
  end

  # Builds a sheet with a data block, then `blank_count` fully blank rows, then
  # a second data block — mimicking a bill with a genuine gap (e.g. day-batched
  # sections separated by blank rows) rather than the footer-residue shape
  # `.build` covers. Used to exercise ParcelBillParser::MAX_CONSECUTIVE_BLANK_ROWS:
  # when blank_count exceeds it, `rows_after` sits past where the breaker
  # trips, so if the breaker didn't record an error, that data would be
  # silently dropped.
  def self.build_with_gap(rows_before:, blank_count:, rows_after:, headers: HEADERS, sheet_name: "gap")
    path = Rails.root.join("tmp", "parcel_bill_#{SecureRandom.hex(6)}.xlsx").to_s
    Axlsx::Package.new do |p|
      p.workbook.add_worksheet(name: sheet_name) do |sheet|
        sheet.add_row headers
        rows_before.each { |r| sheet.add_row(headers.map { |h| r[h] }) }
        blank_count.times { sheet.add_row(Array.new(headers.size)) }
        rows_after.each { |r| sheet.add_row(headers.map { |h| r[h] }) }
      end
      p.serialize(path)
    end
    path
  end

  def self.build_with_headers(headers, rows:, totals:, sheet_name:)
    path = Rails.root.join("tmp", "parcel_bill_#{SecureRandom.hex(6)}.xlsx").to_s
    Axlsx::Package.new do |p|
      # Axlsx applies a date-only number format to Time values by default,
      # which truncates the time-of-day on the xlsx->Roo round trip. Use an
      # explicit datetime format so 发货时间 keeps its hh:mm:ss.
      datetime_style = p.workbook.styles.add_style(format_code: "yyyy-mm-dd hh:mm:ss")
      shipped_at_index = headers.index("发货时间")

      p.workbook.add_worksheet(name: sheet_name) do |sheet|
        sheet.add_row headers
        rows.each do |r|
          styles = Array.new(headers.size)
          styles[shipped_at_index] = datetime_style
          sheet.add_row(headers.map { |h| r[h] }, style: styles)
        end
        totals.each do |t|
          blanks = Array.new(headers.size - 1)
          sheet.add_row(blanks + [ t ])
        end
      end
      p.serialize(path)
    end
    path
  end
  # --- 哆啦任意门 (Doragate) statement ------------------------------------
  # Mirrors the carrier's own bill: a 汇总 summary sheet first, then one detail
  # sheet per billing period, each with its header row and a SUM footer that
  # carries only 件数 and 费用总金额.
  DORAGATE_HEADERS = [
    "计费时间", "客户名称", "客户订单号", "运单号", "派送单号", "运输方式", "国家", "邮编",
    "件数", "结算重量(KG)", "币种", "运费", "操作费", "偏远费", "其他费用", "费用总金额"
  ].freeze

  def self.doragate_row(code:, waybill: "DOR0229399275CN", total: 74.05, **over)
    {
      "计费时间" => Date.new(2026, 10, 26),
      "客户名称" => "千阳贸易",
      "客户订单号" => code,
      "运单号" => waybill,
      "派送单号" => "YWE00001676211752",
      "运输方式" => "美国标准（A带电）",
      "国家" => "美国",
      "邮编" => "30040",
      "件数" => 1,
      "结算重量(KG)" => 0.854,
      "币种" => "人民币",
      "运费" => 64.05,
      "操作费" => 10,
      "偏远费" => 0,
      "其他费用" => 0,
      "费用总金额" => total
    }.merge(over.transform_keys(&:to_s))
  end

  # sheets: { "1026" => [rows], "1027-1030" => [rows] }. The footer SUM row is
  # appended to each detail sheet automatically.
  def self.build_doragate(sheets:, summary: true)
    path = Rails.root.join("tmp", "parcel_bill_#{SecureRandom.hex(6)}.xlsx").to_s
    Axlsx::Package.new do |p|
      date_style = p.workbook.styles.add_style(format_code: "yyyy-mm-dd")
      date_index = DORAGATE_HEADERS.index("计费时间")

      if summary
        p.workbook.add_worksheet(name: "汇总") do |sheet|
          sheet.add_row [ "2026年10月千阳贸易小包应收对账单" ]
          sheet.add_row []
          sheet.add_row [ "序号", "日期", "件数", "应付款", "实付", "账户欠款", "备注" ]
          sheet.add_row [ 1, "2026-10-26", 1, 74.05, 0, 74.05, nil ]
        end
      end

      sheets.each do |name, rows|
        p.workbook.add_worksheet(name: name) do |sheet|
          sheet.add_row DORAGATE_HEADERS
          rows.each do |r|
            styles = Array.new(DORAGATE_HEADERS.size)
            styles[date_index] = date_style
            sheet.add_row(DORAGATE_HEADERS.map { |h| r[h] }, style: styles)
          end
          footer = Array.new(DORAGATE_HEADERS.size)
          footer[DORAGATE_HEADERS.index("件数")] = rows.size
          footer[DORAGATE_HEADERS.index("费用总金额")] = rows.sum { |r| r["费用总金额"].to_f }
          sheet.add_row footer
        end
      end
      p.serialize(path)
    end
    path
  end
end
