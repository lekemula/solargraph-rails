module PostsHelper
  # The title of a post, or a placeholder.
  #
  # @return [String]
  def post_title(post)
    post.to_s
  end

  # @return [Array<Post>]
  def posts
    [Post.new]
  end
end
