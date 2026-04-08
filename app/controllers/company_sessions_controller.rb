class CompanySessionsController < AdminController
  skip_before_action :authorize_page!

  def update
    company = current_user.companies.find(params[:id])
    session[:company_id] = company.id
    redirect_back fallback_location: authenticated_root_path
  end
end
