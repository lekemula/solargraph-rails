class PostsController < ApplicationController
  helper_method :page_title

  def show; end

  private

  # @return [String]
  def page_title
    'Posts'
  end

  def load_comments
    []
  end
end
