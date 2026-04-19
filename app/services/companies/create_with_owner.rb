module Companies
  class CreateWithOwner
    Result = Struct.new(:company, :membership, keyword_init: true)

    def initialize(user, attributes)
      @user = user
      @attributes = attributes
    end

    def call
      ActiveRecord::Base.transaction do
        company = Company.create!(@attributes)
        membership = Membership.create!(
          company: company,
          user: @user,
          role: :owner
        )
        Result.new(company: company, membership: membership)
      end
    end
  end
end
