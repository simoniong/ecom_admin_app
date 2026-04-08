class CompaniesController < AdminController
  before_action :require_owner!

  def edit
    @company = current_company
  end

  def update
    @company = current_company
    if @company.update(company_params)
      redirect_to edit_company_path, notice: t("companies.updated")
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

  def company_params
    params.require(:company).permit(:name)
  end
end
