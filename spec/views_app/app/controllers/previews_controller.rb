class PreviewsController < ApplicationController
  def show
    render partial: "posts/summary", locals: { author: current_user }
  end

  def draft
    @draft = Post.new
    render partial: "shared/draft"
  end
end
