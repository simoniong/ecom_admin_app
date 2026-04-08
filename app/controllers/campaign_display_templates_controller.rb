class CampaignDisplayTemplatesController < AdminController
  before_action :set_template, only: [ :update, :destroy ]

  def create
    @template = current_company.campaign_display_templates.build(template_params)
    @template.user = current_user
    @template.last_active_at = Time.current

    if @template.save
      redirect_to ad_campaigns_path(template_id: @template.id), notice: t("campaign_display_templates.created")
    else
      redirect_to ad_campaigns_path, alert: @template.errors.full_messages.join(", ")
    end
  end

  def update
    if @template.update(template_params)
      @template.touch_active!
      redirect_to ad_campaigns_path(template_id: @template.id), notice: t("campaign_display_templates.updated")
    else
      redirect_to ad_campaigns_path, alert: @template.errors.full_messages.join(", ")
    end
  end

  def destroy
    @template.destroy
    redirect_to ad_campaigns_path, notice: t("campaign_display_templates.deleted")
  end

  private

  def set_template
    @template = current_company.campaign_display_templates.find(params[:id])
  end

  def template_params
    params.require(:campaign_display_template).permit(:name, visible_columns: [])
  end
end
