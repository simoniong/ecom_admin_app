module PackagesHelper
  # A list link that keeps the current filters and overrides only the given
  # params. request.query_parameters has STRING keys; merging symbol keys onto
  # it emits the same param twice and only works by Rack's last-one-wins
  # accident, so normalize to symbols first. nil overrides drop the param
  # (that is how the "all" pills clear a filter).
  #
  # Callers pass page: nil when changing a filter or sort — keeping the old page
  # would land the user on an empty page 3 of a now-shorter list.
  def packages_list_path(overrides)
    packages_path(request.query_parameters.symbolize_keys.merge(overrides).compact)
  end
end
