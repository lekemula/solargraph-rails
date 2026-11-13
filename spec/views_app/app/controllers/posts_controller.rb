class PostsController < ApplicationController
  before_action :set_post
  helper_method :page_title

  def show
    @comments = load_comments
  end

  def edit
    @post = Post.new
  end

  private

  def set_post
    @post = Post.new
  end

  # @return [String]
  def page_title
    'Posts'
  end

  # @return [Array<String>]
  def load_comments
    []
  end
end
