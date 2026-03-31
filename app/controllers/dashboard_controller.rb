class DashboardController < AdminController
  def show
    @range_key = params[:range].presence || "past_7_days"
    @metrics = DashboardMetricsService.new(
      current_user,
      range_key: @range_key,
      start_date: params[:start_date],
      end_date: params[:end_date]
    ).call
    @range_key = @metrics[:range_key]
  end
end
