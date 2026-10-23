# Rolls the Dashboard's sync runs up for one scope: a run is recorded per unit
# of work (a store or an ad account), and a source's state is the roll-up of
# its units. Everything is read through the scopes the Dashboard is already
# showing, so the badge never reports on stores or ad accounts the user can't
# see.
class SyncStatus
  Source = Data.define(:key, :state, :last_success_at, :failures, :history, :signature, :acknowledged)

  HISTORY_LIMIT = 5

  AD_PLATFORMS = { "meta_ads" => "meta", "google_ads" => "google" }.freeze

  def initialize(company:, store_scope:, ad_scope:, user:)
    @company = company
    @store_scope = store_scope
    @ad_scope = ad_scope
    @user = user
  end

  def sources
    rollups.map { |rollup| rollup[:source] }
  end

  def badge
    {
      state: badge_state,
      failed_count: failed_count,
      running_count: running_count,
      updated_at: updated_at
    }
  end

  # Driven by units rather than the rolled-up source state: a source whose
  # latest runs are a mix of failed and running rolls up to :failed, but the
  # poll still has to follow the running unit to its end.
  def running?
    running_count.positive?
  end

  def acknowledge!(source_key)
    source = sources.find { |candidate| candidate.key == source_key.to_s }
    raise ArgumentError, "unknown sync source: #{source_key}" if source.nil?

    ack = SyncAcknowledgement.find_or_initialize_by(user: @user, company: @company, source: source.key)
    ack.update!(signature: source.signature, acknowledged_at: Time.current)
    @acknowledgements = nil
    @rollups = nil
    ack
  end

  private

  # Each entry carries the Source itself plus whether any of its units is
  # actually running, which the source's single state value can hide.
  def rollups
    @rollups ||= SyncRun::SOURCES.map { |key| rollup(key) }
  end

  def rollup(key)
    units = units_for(key)
    latest = latest_runs(key, units)
    successes = latest_successes(key, units)
    failing = units.select { |unit| latest[unit.id]&.effective_status == "failed" }
    signature = signature_for(failing, latest)

    source = Source.new(
      key: key,
      state: state_for(units, latest),
      last_success_at: successes.values.filter_map { |run| run.finished_at || run.started_at }.min,
      failures: failing.map { |unit| { target_name: unit_name(unit), message: latest[unit.id].effective_error } },
      history: history_for(key, units),
      signature: signature,
      acknowledged: acknowledged?(key, signature, failing, successes)
    )

    { source: source, running: units.any? { |unit| latest[unit.id]&.effective_status == "running" } }
  end

  def state_for(units, latest)
    statuses = units.filter_map { |unit| latest[unit.id]&.effective_status }

    return :never if statuses.empty?
    return :failed if statuses.include?("failed")
    return :running if statuses.include?("running")

    :succeeded
  end

  # The ad sources each take one platform's accounts; the Shopify sources both
  # run over the stores.
  def units_for(key)
    platform = AD_PLATFORMS[key]
    platform ? ad_accounts_on(platform) : stores
  end

  def stores
    @stores ||= @store_scope.to_a.sort_by { |store| store.display_name.to_s }
  end

  def ad_accounts_on(platform)
    @ad_accounts_by_platform ||= @ad_scope.to_a.sort_by { |account| unit_name(account) }.group_by(&:platform)
    @ad_accounts_by_platform.fetch(platform, [])
  end

  # Stores carry a display_name that falls back to the shop domain; an ad
  # account only has the name the platform reported when it was connected.
  def unit_name(unit)
    unit.is_a?(ShopifyStore) ? unit.display_name : unit.account_name.presence || unit.account_id
  end

  def runs_for(key, units)
    SyncRun.where(company_id: @company.id, source: key, target: units)
  end

  def latest_runs(key, units)
    return {} if units.empty?

    distinct_on_unit(runs_for(key, units)).index_by(&:target_id)
  end

  def latest_successes(key, units)
    return {} if units.empty?

    distinct_on_unit(runs_for(key, units).succeeded).index_by(&:target_id)
  end

  # One query per source for the newest run of every unit, rather than one
  # query per unit.
  def distinct_on_unit(relation)
    relation.select("DISTINCT ON (target_type, target_id) sync_runs.*")
            .order(Arel.sql("target_type, target_id, started_at DESC"))
  end

  def history_for(key, units)
    return [] if units.empty?

    runs_for(key, units).order(started_at: :desc).limit(HISTORY_LIMIT).to_a
  end

  def signature_for(failing, latest)
    return nil if failing.empty?

    lines = failing.map do |unit|
      run = latest[unit.id]
      "#{run.target_type}:#{run.target_id}:#{SyncRun.normalize_error(run.effective_error)}"
    end

    Digest::SHA256.hexdigest(lines.sort.join("\n"))
  end

  def acknowledgements
    @acknowledgements ||= SyncAcknowledgement.where(user_id: @user.id, company_id: @company.id).index_by(&:source)
  end

  def acknowledged?(key, signature, failing, successes)
    return false if signature.nil?

    ack = acknowledgements[key]
    return false unless ack&.signature == signature

    streak_start = newest_streak_start(key, failing, successes)
    streak_start.nil? || ack.acknowledged_at >= streak_start
  end

  # A unit's streak start is the started_at of its earliest failed run since
  # its last success, so an ack older than the newest streak no longer covers
  # the failure. Only reached once an ack with a matching signature exists,
  # which keeps this query off the common path.
  def newest_streak_start(key, failing, successes)
    base = effectively_failed(runs_for(key, failing), key)

    scope = failing.map { |unit|
      unit_scope = base.where(target_id: unit.id)
      since = successes[unit.id]&.started_at
      since ? unit_scope.where("started_at > ?", since) : unit_scope
    }.reduce(:or)

    scope.group(:target_type, :target_id).minimum(:started_at).values.max
  end

  # Mirrors SyncRun#effective_status in SQL: a running row past its source's
  # threshold is part of the failure streak too.
  def effectively_failed(relation, key)
    relation.where("status = ? OR (status = ? AND started_at < ?)",
                   "failed", "running", SyncRun::STALE_AFTER.fetch(key).ago)
  end

  def failed_count
    sources.count { |source| source.state == :failed && !source.acknowledged }
  end

  def running_count
    rollups.count { |rollup| rollup[:running] }
  end

  # Sources with no runs at all are ignored here: they would otherwise hold the
  # badge back from green forever on a scope that never used that source.
  def updated_at
    sources.reject { |source| source.state == :never }.filter_map(&:last_success_at).min
  end

  def badge_state
    return :never if sources.all? { |source| source.state == :never }
    return :failed if failed_count.positive?
    return :running if running_count.positive?

    :ok
  end
end
