class CampaignDisplayTemplatesController < AdminController
  before_action :set_template, only: [ :update, :destroy ]

  def create
    @template = current_company.campaign_display_templates.build(template_params)
    @template.user = current_user
    @template.last_active_at = Time.current

    if @template.save
      respond_to do |format|
        format.html { redirect_to ad_campaigns_path(template_id: @template.id), notice: t("campaign_display_templates.created") }
        format.json { render json: { redirect_url: ad_campaigns_path(template_id: @template.id) } }
      end
    else
      respond_to do |format|
        format.html { redirect_to ad_campaigns_path, alert: @template.errors.full_messages.join(", ") }
        format.json { render json: { errors: @template.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def update
    if @template.update(template_params)
      @template.touch_active!
      respond_to do |format|
        format.html { redirect_to ad_campaigns_path(template_id: @template.id), notice: t("campaign_display_templates.updated") }
        format.json { render json: { redirect_url: ad_campaigns_path(template_id: @template.id) } }
      end
    else
      respond_to do |format|
        format.html { redirect_to ad_campaigns_path, alert: @template.errors.full_messages.join(", ") }
        format.json { render json: { errors: @template.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def destroy
    @template.destroy
    respond_to do |format|
      format.html { redirect_to ad_campaigns_path, notice: t("campaign_display_templates.deleted") }
      format.json { render json: { redirect_url: ad_campaigns_path } }
    end
  end

  private

  def set_template
    @template = current_company.campaign_display_templates.find(params[:id])
  end

  def template_params
    params.require(:campaign_display_template).permit(:name, visible_columns: [])
  end
end
