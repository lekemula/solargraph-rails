# A collection of posts whose element type is not a type parameter, like a model's relation
class PostArchive
  include Enumerable

  # @return [Post, nil]
  def first
    Post.new
  end
end
