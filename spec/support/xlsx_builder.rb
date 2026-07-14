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
end
