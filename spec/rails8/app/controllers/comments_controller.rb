class CommentsController < ApplicationController
  def index
    @comment = Comment.new
  end
end
