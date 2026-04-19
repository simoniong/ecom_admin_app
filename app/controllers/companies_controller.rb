class CompaniesController < AdminController
  before_action :require_owner!

  def edit
    @company = current_company
  end

  def update
    @company = current_company
    if @company.update(general_params)
      redirect_to edit_company_path, notice: t("companies.updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def update_tracking
    @company = current_company
    if @company.update(tracking_params)
      redirect_to edit_company_path, notice: t("companies.tracking_updated")
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def require_owner!
    unless current_membership&.owner?
      redirect_to authenticated_root_path, alert: t("companies.no_permission")
    end
  end

  def general_params
    params.require(:company).permit(:name, :locale)
  end

  def tracking_params
    permitted = params.require(:company)
      .permit(:tracking_enabled, :tracking_api_key, :tracking_mode,
              :tracking_backfill_days, :tracking_backfill_all)

    want_enabled = ActiveModel::Type::Boolean.new.cast(permitted[:tracking_enabled])
    new_key = permitted[:tracking_api_key].presence

    if want_enabled && new_key
      tracking_config_attrs(new_key, permitted).merge(tracking_enabled: true)
    elsif want_enabled
      { tracking_enabled: true }
    else
      { tracking_enabled: false }
    end
  end

  def tracking_config_attrs(new_key, permitted)
    mode = permitted[:tracking_mode]
    days = resolve_backfill_days(mode, permitted)
    {
      tracking_api_key: new_key,
      tracking_mode: mode,
      tracking_backfill_days: days,
      tracking_starts_at: Company.starts_at_for(mode: mode, days: days)
    }
  end

  def resolve_backfill_days(mode, permitted)
    return nil unless mode == "backfill"
    return nil if ActiveModel::Type::Boolean.new.cast(permitted[:tracking_backfill_all])

    raw = permitted[:tracking_backfill_days].presence
    Integer(raw, exception: false) || Company::DEFAULT_TRACKING_BACKFILL_DAYS
  end
end
