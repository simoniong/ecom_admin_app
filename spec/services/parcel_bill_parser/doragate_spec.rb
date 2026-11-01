require "rails_helper"

RSpec.describe ParcelBillParser::Doragate do
  def parse(path)
    ParcelBillParser.new(path).call
  end

  it "is detected automatically and maps the columns onto parcel attributes" do
    path = XlsxBuilder.build_doragate(sheets: {
      "1026" => [ XlsxBuilder.doragate_row(code: "XMBDP1004342") ]
    })

    result = parse(path)

    expect(result[:errors]).to be_empty
    expect(result[:rows].size).to eq(1)
    row = result[:rows].first
    expect(row).to include(
      identifier: "XMBDP1004342",
      package_code: "XMBDP1004342",
      order_name: nil,
      internal_no: "DOR0229399275CN",
      tracking_number: "YWE00001676211752",
      service_channel: "美国标准（A带电）",
      country: "美国",
      zone: nil,
      actual_weight_g: nil,
      billed_weight_g: 854,
      shipped_at: Time.utc(2026, 10, 26),
      tax_cny: nil
    )
    expect(row[:freight_cny]).to eq(BigDecimal("64.05"))
    expect(row[:registration_fee_cny]).to eq(BigDecimal("10")) # the carrier's 操作费
    expect(row[:remote_area_fee_cny]).to eq(BigDecimal("0"))
  end

  it "adds the ¥2 handling fee on top of 费用总金额 and flags it as derived" do
    path = XlsxBuilder.build_doragate(sheets: {
      "1026" => [ XlsxBuilder.doragate_row(code: "XMBDP1", total: 74.05) ]
    })

    row = parse(path)[:rows].first

    expect(row[:operation_fee_cny]).to eq(BigDecimal("2"))
    expect(row[:cost_cny]).to eq(BigDecimal("76.05"))
    expect(row[:derived_operation_fee]).to be(true)
  end

  it "reads every detail sheet, skips the summary sheet and each SUM footer" do
    path = XlsxBuilder.build_doragate(sheets: {
      "1026" => [ XlsxBuilder.doragate_row(code: "XMBDP1", waybill: "DOR1") ],
      "1027-1030" => [
        XlsxBuilder.doragate_row(code: "XMBDP2", waybill: "DOR2"),
        XlsxBuilder.doragate_row(code: "XMBDP3", waybill: "DOR3")
      ]
    })

    result = parse(path)

    expect(result[:errors]).to be_empty
    expect(result[:rows].map { |r| r[:identifier] }).to eq(%w[XMBDP1 XMBDP2 XMBDP3])
  end

  it "works without a summary sheet" do
    path = XlsxBuilder.build_doragate(summary: false, sheets: {
      "1026" => [ XlsxBuilder.doragate_row(code: "XMBDP1") ]
    })

    expect(parse(path)[:rows].size).to eq(1)
  end

  it "falls back to the waybill when 派送单号 is blank" do
    path = XlsxBuilder.build_doragate(sheets: {
      "1026" => [ XlsxBuilder.doragate_row(code: "XMBDP1", waybill: "DOR0229400964CN", "派送单号" => "") ]
    })

    expect(parse(path)[:rows].first[:tracking_number]).to eq("DOR0229400964CN")
  end

  it "reports a blank waybill with its sheet and line" do
    path = XlsxBuilder.build_doragate(sheets: {
      "1026" => [ XlsxBuilder.doragate_row(code: "XMBDP1", waybill: nil) ]
    })

    result = parse(path)

    expect(result[:rows]).to be_empty
    expect(result[:errors]).to eq([ "工作表「1026」第 2 列：运单号 為空" ])
  end

  it "reports a blank or non-numeric total" do
    path = XlsxBuilder.build_doragate(sheets: {
      "1026" => [
        XlsxBuilder.doragate_row(code: "XMBDP1", total: nil),
        XlsxBuilder.doragate_row(code: "XMBDP2", total: "abc")
      ]
    })

    result = parse(path)

    expect(result[:rows]).to be_empty
    expect(result[:errors]).to all(include("费用总金额 為空或非數字"))
  end

  it "reports an out-of-range total" do
    path = XlsxBuilder.build_doragate(sheets: {
      "1026" => [ XlsxBuilder.doragate_row(code: "XMBDP1", total: -5) ]
    })

    expect(parse(path)[:errors].first).to include("费用总金额 數值超出範圍")
  end

  it "rejects a row billed in a currency other than CNY" do
    path = XlsxBuilder.build_doragate(sheets: {
      "1026" => [ XlsxBuilder.doragate_row(code: "XMBDP1", "币种" => "美元") ]
    })

    result = parse(path)

    expect(result[:rows]).to be_empty
    expect(result[:errors].first).to include("币种「美元」不是人民币")
  end

  it "parses a 计费时间 written as text" do
    path = XlsxBuilder.build_doragate(sheets: {
      "1026" => [ XlsxBuilder.doragate_row(code: "XMBDP1", "计费时间" => "2026-10-28") ]
    })

    expect(parse(path)[:rows].first[:shipped_at]).to eq(Time.utc(2026, 10, 28))
  end

  it "leaves shipped_at nil for an unparseable 计费时间" do
    path = XlsxBuilder.build_doragate(sheets: {
      "1026" => [ XlsxBuilder.doragate_row(code: "XMBDP1", "计费时间" => "not a date") ]
    })

    expect(parse(path)[:rows].first[:shipped_at]).to be_nil
  end

  it "stops after a long run of blank rows and says so" do
    limit = ParcelBillParser::MAX_CONSECUTIVE_BLANK_ROWS
    path = XlsxBuilder.build_with_gap(
      headers: XlsxBuilder::DORAGATE_HEADERS,
      sheet_name: "1026",
      rows_before: [ XlsxBuilder.doragate_row(code: "XMBDP1") ],
      blank_count: limit + 5,
      rows_after: [ XlsxBuilder.doragate_row(code: "XMBDP2") ]
    )

    result = parse(path)

    expect(result[:rows].map { |r| r[:identifier] }).to eq(%w[XMBDP1])
    expect(result[:errors].first).to include("工作表「1026」").and include("連續 #{limit} 列空白")
  end

  it "still reports missing headers for a file that is neither format" do
    path = XlsxBuilder.build_with_headers([ "foo", "bar" ], rows: [], totals: [], sheet_name: "x")

    result = parse(path)

    expect(result[:rows]).to be_empty
    expect(result[:errors].first).to include("缺少必要欄位")
  end

  it "parses Dianxiaomi bills exactly as before" do
    path = XlsxBuilder.build(rows: [
      XlsxBuilder.row(seq: 1, identifier: "XMBDE2012381", order_name: "PKS#3037", cost: 239.732)
    ])

    row = parse(path)[:rows].first

    expect(row[:identifier]).to eq("XMBDE2012381")
    expect(row[:order_name]).to eq("PKS#3037")
    expect(row).not_to have_key(:package_code)
  end
end
