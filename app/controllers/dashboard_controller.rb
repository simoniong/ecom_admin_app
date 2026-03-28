class DashboardController < AdminController
  def show
    @range_key = params[:range].presence || "past_7_days"
    @metrics = DashboardMetricsService.new(current_user, range_key: @range_key).call
  end
end
