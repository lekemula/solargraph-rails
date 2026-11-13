class PreviewsController < ApplicationController
  def show
    render partial: "posts/summary", locals: { author: current_user }
  end
end
