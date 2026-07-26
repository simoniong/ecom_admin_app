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

  # Shopify's CDN serves a resized copy when the dimensions are spliced into the
  # filename: painting.jpg -> painting_100x100.jpg. The packing list renders up
  # to 50 rows of several SKUs each, so linking the originals would be tens of
  # megabytes per page.
  #
  # An unrecognized URL shape is returned UNCHANGED rather than guessed at: the
  # cost of being wrong here is a broken link (no image at all), while the cost
  # of not transforming is a slow image. Slow beats missing.
  IMAGE_EXTENSIONS = %w[jpg jpeg png webp gif].freeze

  def shopify_image_variant(url, size)
    return nil if url.blank?

    # Split the query off first — ?v= is Shopify's cache buster and must survive.
    path, _, query = url.to_s.partition("?")
    extension = File.extname(path).delete_prefix(".")
    return url unless IMAGE_EXTENSIONS.include?(extension.downcase)

    resized = "#{path.delete_suffix(".#{extension}")}_#{size}.#{extension}"
    query.present? ? "#{resized}?#{query}" : resized
  end
end
