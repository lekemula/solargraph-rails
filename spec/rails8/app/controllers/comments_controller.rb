class CommentsController < ApplicationController
  def index
    @comment = Comment.new
  end

  def summary
    render partial: "summary", locals: { comment: @comment }
  end
end
