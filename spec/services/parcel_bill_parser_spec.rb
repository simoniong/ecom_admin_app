require "rails_helper"

RSpec.describe ParcelBillParser do
  def build_file(rows:, totals: [ 58_578.977 ])
    XlsxBuilder.build(rows: rows, totals: totals)
  end

  it "maps the Chinese headers onto parcel attributes" do
    path = build_file(rows: [
      XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: 239.732)
    ])

    result = described_class.new(path).call

    expect(result[:errors]).to be_empty
    expect(result[:rows].size).to eq(1)

    row = result[:rows].first
    expect(row[:identifier]).to eq("XMBDE2012381")
    expect(row[:order_name]).to eq("PKS#3037")
    expect(row[:internal_no]).to eq("DOR0201415428CN")
    expect(row[:tracking_number]).to eq("SPXORH011122606010001237")
    expect(row[:service_channel]).to eq("美国标准（A带电）")
    expect(row[:country]).to eq("美国")
    expect(row[:actual_weight_g]).to eq(2423)
    expect(row[:billed_weight_g]).to eq(2421)
    expect(row[:cost_cny]).to eq(BigDecimal("239.73"))
    expect(row[:registration_fee_cny]).to eq(BigDecimal("15"))
    expect(row[:operation_fee_cny]).to eq(BigDecimal("2"))
    expect(row[:shipped_at]).to eq(Time.utc(2026, 6, 1, 21, 48, 26))
  end

  it "skips a row whose 序号 is blank even though it would otherwise parse and validate cleanly" do
    # This isolates the SEQUENCE_HEADER guard from the "订单编号 blank" validation
    # path: 订单编号 and cost are both populated here, so if the guard were ever
    # deleted this row would sail through validation and land in result[:rows].
    path = build_file(
      rows: [
        XlsxBuilder.row(seq: nil, identifier: "SHOULD-NOT-APPEAR", order_name: "PKS#9999")
      ],
      totals: []
    )

    result = described_class.new(path).call

    expect(result[:rows]).to be_empty
    expect(result[:errors]).to be_empty
    expect(result[:rows].map { |r| r[:identifier] }).not_to include("SHOULD-NOT-APPEAR")
  end

  it "excludes the footer total rows (they have no 序号)" do
    path = build_file(
      rows: [
        XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037"),
        XlsxBuilder.row(seq: 2, identifier: "XMBDE2012382", order_name: "PKS#3038")
      ],
      totals: [ 58_578.977, 239_735.764 ]
    )

    result = described_class.new(path).call

    expect(result[:rows].size).to eq(2)
    expect(result[:rows].map { |r| r[:identifier] })
      .to contain_exactly("XMBDE2012381", "XMBDE2012382")
  end

  it "reports a row whose identifier is blank" do
    path = build_file(rows: [
      XlsxBuilder.row(seq: 1, identifier: nil, order_name: "PKS#3037")
    ])

    result = described_class.new(path).call

    expect(result[:rows]).to be_empty
    expect(result[:errors].first).to include("订单编号")
  end

  it "reports a row whose cost is blank" do
    path = build_file(rows: [
      XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: nil)
    ])

    result = described_class.new(path).call

    expect(result[:rows]).to be_empty
    expect(result[:errors].first).to include("加单总运费")
  end

  # A garbage cell (e.g. a tracking number pasted into 加单总运费) can still
  # parse as a BigDecimal — it just isn't a plausible shipping cost. Left
  # unchecked, a value like this sails through the parser and 500s later at
  # confirm time against decimal(10,2), taking the whole import down with no
  # indication of which row. It must be caught here instead, where the row
  # number is still known.
  it "reports a row whose cost is zero or negative" do
    path = build_file(rows: [
      XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: -99_999)
    ])

    result = described_class.new(path).call

    expect(result[:rows]).to be_empty
    expect(result[:errors].first).to include("第 2 列") # sheet row 2 — row 1 is the header
    expect(result[:errors].first).to include("超出範圍")
  end

  it "reports a row whose cost is too large to fit the decimal(10,2) column" do
    path = build_file(rows: [
      XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: 100_000_000)
    ])

    result = described_class.new(path).call

    expect(result[:rows]).to be_empty
    expect(result[:errors].first).to include("超出範圍")
  end

  it "accepts the largest cost that still fits decimal(10,2)" do
    path = build_file(rows: [
      XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: 99_999_999.99)
    ])

    result = described_class.new(path).call

    expect(result[:errors]).to be_empty
    expect(result[:rows].size).to eq(1)
    expect(result[:rows].first[:cost_cny]).to eq(BigDecimal("99999999.99"))
  end

  it "reports a missing required header instead of silently mis-mapping" do
    path = Rails.root.join("tmp", "bad_#{SecureRandom.hex(4)}.xlsx").to_s
    Axlsx::Package.new do |p|
      p.workbook.add_worksheet(name: "x") { |s| s.add_row [ "序号", "订单编号" ] }
      p.serialize(path)
    end

    result = described_class.new(path).call

    expect(result[:rows]).to be_empty
    expect(result[:errors].first).to include("加单总运费（RMB)")
  end

  it "returns an errors array instead of raising when the file is not a readable xlsx" do
    path = Rails.root.join("tmp", "corrupt_#{SecureRandom.hex(4)}.xlsx").to_s
    File.write(path, "this is not a zip/xlsx file at all")

    result = described_class.new(path).call

    expect(result[:rows]).to eq([])
    expect(result[:errors].first).to include("無法讀取檔案")
  end

  describe "deriving cost_cny when 加单总运费（RMB) is absent (the July bill shape)" do
    # Mutation-test (b): if the derivation branch were removed entirely, this
    # July-shaped row (no 加单总运费（RMB) column at all) would have a blank
    # cost_cny, fail validation, and land in result[:errors] instead of
    # result[:rows] — the assertions below would fail.
    it "derives cost_cny as 总运费（RMB) + the default handling fee and flags the row as derived" do
      path = XlsxBuilder.build_july(rows: [
        XlsxBuilder.july_row(seq: 1, identifier: "JUL0001", order_name: "PKS#4001", subtotal: 122.732)
      ])

      result = described_class.new(path).call

      expect(result[:errors]).to be_empty
      row = result[:rows].first
      # 122.732 rounds to 122.73 before the fee is added, then +2.
      expect(row[:cost_cny]).to eq(BigDecimal("124.73"))
      expect(row[:operation_fee_cny]).to eq(ParcelBillParser::DEFAULT_OPERATION_FEE_CNY)
      expect(row[:derived_operation_fee]).to be(true)
    end

    # Mutation-test (c): the expected total is hardcoded to ¥2/parcel, not
    # computed from the constant — if DEFAULT_OPERATION_FEE_CNY were changed
    # to 0, the parser would sum to 160.51 instead of 166.51 and this fails.
    it "sums several derived rows to exactly Σsubtotal + (count × ¥2)" do
      rows = [
        XlsxBuilder.july_row(seq: 1, identifier: "JUL0001", order_name: "PKS#4001", subtotal: 100),
        XlsxBuilder.july_row(seq: 2, identifier: "JUL0002", order_name: "PKS#4001", subtotal: 50.50),
        XlsxBuilder.july_row(seq: 3, identifier: "JUL0003", order_name: "PKS#4001", subtotal: 10.01)
      ]
      path = XlsxBuilder.build_july(rows: rows)

      result = described_class.new(path).call

      expect(result[:errors]).to be_empty
      expect(result[:rows].sum { |r| r[:cost_cny] }).to eq(BigDecimal("166.51"))
      expect(result[:rows].size).to eq(3)
    end

    # Accepts the bare "总运费" spelling too (not just "总运费（RMB)"), since both
    # have been seen in the wild — built directly (not via .build_july, which
    # always uses the RMB-suffixed spelling) to isolate this header variant.
    it "also accepts the bare 总运费 header spelling when 加单总运费（RMB) and 总运费（RMB) are both absent" do
      headers = XlsxBuilder::JULY_HEADERS.map { |h| h == "总运费（RMB)" ? "总运费" : h }
      row = XlsxBuilder.july_row(seq: 1, identifier: "JUL0001", order_name: "PKS#4001", subtotal: 40)
                       .transform_keys { |k| k == "总运费（RMB)" ? "总运费" : k }
      path = XlsxBuilder.build_with_headers(headers, rows: [ row ], totals: [], sheet_name: "7月")

      result = described_class.new(path).call

      expect(result[:errors]).to be_empty
      expect(result[:rows].first[:cost_cny]).to eq(BigDecimal("42.00"))
      expect(result[:rows].first[:derived_operation_fee]).to be(true)
    end

    # Mutation-test (a): if the "use 加单总运费（RMB) as-is, don't derive"
    # branch were removed (i.e. derivation always ran), this June-shaped row
    # would recompute cost_cny from 总运费 + 操作费 (237.732 + 2 = 239.73)
    # instead of reading the deliberately different billed grand total (300),
    # silently overwriting a correctly billed figure.
    it "reads 加单总运费（RMB) as-is and does not derive, even when 总运费/操作费 are also present and disagree with it" do
      path = build_file(rows: [
        XlsxBuilder.row(seq: 1, identifier: "XMBDE9000001", order_name: "PKS#3037",
                        cost: 300, "总运费" => 237.732, "操作费" => 2)
      ])

      result = described_class.new(path).call

      expect(result[:errors]).to be_empty
      row = result[:rows].first
      expect(row[:cost_cny]).to eq(BigDecimal("300.00"))
      expect(row[:derived_operation_fee]).to be_nil
    end

    it "reports a missing required header when neither 加单总运费（RMB) nor any 总运费 subtotal column is present" do
      headers = XlsxBuilder::JULY_HEADERS - [ "总运费（RMB)" ]
      row = XlsxBuilder.july_row(seq: 1, identifier: "JUL0001", order_name: "PKS#4001").except("总运费（RMB)")
      path = XlsxBuilder.build_with_headers(headers, rows: [ row ], totals: [], sheet_name: "7月")

      result = described_class.new(path).call

      expect(result[:rows]).to be_empty
      expect(result[:errors].first).to include("加单总运费（RMB)")
    end
  end

  describe "the MAX_CONSECUTIVE_BLANK_ROWS breaker" do
    # A bill with a genuine gap (e.g. day-batched sections separated by blank
    # rows) rather than the footer-residue shape: real data sits on both sides
    # of a blank run longer than MAX_CONSECUTIVE_BLANK_ROWS. Parsing must stop
    # at the breaker (dropping the rows after the gap is the whole point of
    # the guard — see the class comment), but that truncation must never be
    # silent: money-bearing rows disappearing from an import with a clean
    # rows=N errors=0 result is exactly the failure mode being guarded
    # against. If the error-append were removed, `errors` would stay empty
    # here and this spec would fail.
    it "stops parsing and reports a non-empty, named error when a blank run exceeds the limit" do
      rows_before = [
        XlsxBuilder.row(seq: 1, identifier: "BEFORE0001", order_name: "PKS#3037")
      ]
      rows_after = [
        XlsxBuilder.row(seq: 2, identifier: "AFTER0001", order_name: "PKS#3037")
      ]
      path = XlsxBuilder.build_with_gap(
        rows_before: rows_before,
        blank_count: ParcelBillParser::MAX_CONSECUTIVE_BLANK_ROWS + 5,
        rows_after: rows_after
      )

      result = described_class.new(path).call

      expect(result[:rows].map { |r| r[:identifier] }).to contain_exactly("BEFORE0001")
      expect(result[:rows].map { |r| r[:identifier] }).not_to include("AFTER0001")

      expect(result[:errors]).not_to be_empty
      expect(result[:errors].join).to include("連續 #{ParcelBillParser::MAX_CONSECUTIVE_BLANK_ROWS} 列空白")
    end
  end
end
