class ApplicationController < ActionController::Base
  include Authentication

  before_action :set_locale

  private

  def set_locale
    @locale = :en
  end
end
