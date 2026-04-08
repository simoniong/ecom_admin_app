class DashboardController < AdminController
  def show
    @range_key = if params[:start_date].present? && params[:end_date].present?
                   "custom"
    elsif DashboardMetricsService::RANGES.key?(params[:range])
                   params[:range]
    else
                   "past_7_days"
    end

    @metrics = DashboardMetricsService.new(
      current_company,
      range_key: @range_key,
      start_date: params[:start_date],
      end_date: params[:end_date]
    ).call
    @range_key = @metrics[:range_key]
  end
end
