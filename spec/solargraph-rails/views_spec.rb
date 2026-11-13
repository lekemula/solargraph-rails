RSpec.describe Solargraph::Rails::Views, :herb do
  def root
    File.expand_path('../views_app', __dir__)
  end

  # Loading the ActionView docs takes seconds, so the examples share one library
  def self.library
    @library ||= Solargraph::Library.load(File.expand_path('../views_app', __dir__)).tap do |library|
      library.map!
      library.catalog
    end
  end

  def library
    self.class.library
  end

  # @param relpath [String]
  # @param line [Integer] 0-based
  # @param needle [String] the text whose first character the cursor is on
  # @return [Array<Solargraph::Pin::Base>]
  def definitions(relpath, line, needle)
    filename = File.join(root, relpath)
    column = File.readlines(filename)[line].index(needle)
    library.definitions_at(filename, line, column)
  end

  it 'resolves ActionView helpers in a view' do
    pin = definitions('app/views/posts/show.html.erb', 1, 'link_to').first

    expect(pin.path).to eq('ActionView::Helpers::UrlHelper#link_to')
    expect(pin.location.filename).to end_with('action_view/helpers/url_helper.rb')
    expect(pin.documentation).to include('Creates an anchor element')
  end

  it 'resolves app helpers in a view' do
    pin = definitions('app/views/posts/show.html.erb', 0, 'post_title').first

    expect(pin.path).to eq('PostsHelper#post_title')
    expect(pin.location.filename).to eq(File.join(root, 'app/helpers/posts_helper.rb'))
    expect(pin.documentation).to include('The title of a post')
  end

  it 'runs views with no matching controller in the application controller\'s view class' do
    layout = 'app/views/layouts/application.html.erb'

    expect(definitions(layout, 1, 'link_to').first&.path).to eq('ActionView::Helpers::UrlHelper#link_to')
  end

  it 'does not resolve view helpers at the top level of a Ruby file' do
    %w[link_to post_title current_user].each_with_index do |helper, line|
      expect(definitions('lib/plain.rb', line, helper)).to be_empty, helper
    end
  end
end
