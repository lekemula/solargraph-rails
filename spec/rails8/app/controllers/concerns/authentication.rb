module Authentication
  extend ActiveSupport::Concern

  included do
    helper_method :current_user
  end

  private

  # @return [User]
  def current_user
    @current_user ||= User.new
  end
end
