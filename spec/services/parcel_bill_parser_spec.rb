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
end
