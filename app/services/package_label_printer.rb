# Validates a set of pending_label packages and fetches their combined Raydo
# label PDF (one carrier request; Raydo merges multiple order_ids into one PDF).
# Batch requires a single label_print_type (no PDF-merge dependency).
# See docs/superpowers/specs/2026-07-22-order-packing-phase2d-label-printing-design.md.
class PackageLabelPrinter
  Result = Struct.new(:success, :pdf, :filename, :error, keyword_init: true) do
    def success? = !!success
  end

  def initialize(packages)
    @packages = Array(packages)
  end

  def call
    return failure(:empty) if @packages.empty?
    return failure(:invalid_state) unless @packages.all?(&:pending_label?)
    return failure(:no_order) unless @packages.all? { |p| p.raydo_order_id.present? }

    channels = @packages.map(&:logistics_channel)
    return failure(:no_channel) if channels.any?(&:nil?)

    types = channels.map(&:label_print_type).uniq
    return failure(:mixed_type) if types.size > 1

    return failure(:mixed_account) if channels.map(&:logistics_account_id).uniq.size > 1

    account = channels.first.logistics_account
    return failure(:url2_missing) if account.url2_base.blank?

    pdf = FulfillmentService.for(account).label_pdf(@packages.map(&:raydo_order_id), types.first)
    Result.new(success: true, pdf: pdf, filename: filename)
  rescue FulfillmentService::Error => e
    failure(e.message)
  end

  private

  def filename
    if @packages.size == 1
      "label_#{@packages.first.package_code}.pdf"
    else
      "labels_#{@packages.size}.pdf"
    end
  end

  def failure(error)
    Result.new(success: false, error: error)
  end
end
