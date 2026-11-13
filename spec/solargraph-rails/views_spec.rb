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
    column += 1 if needle.start_with?("@")
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

  it 'resolves helper_method targets declared in a concern of a parent controller' do
    pin = definitions('app/views/posts/show.html.erb', 2, 'current_user').first

    expect(pin.name).to eq('current_user')
    expect(pin.location.filename).to eq(File.join(root, 'app/controllers/concerns/authentication.rb'))
    expect(pin.location.range.start.line).to eq(10)
    expect(pin.return_type.to_s).to eq('User')
  end

  it 'resolves helper_method targets declared in the view\'s controller' do
    pin = definitions('app/views/posts/show.html.erb', 2, 'page_title').first

    expect(pin.name).to eq('page_title')
    expect(pin.location.filename).to eq(File.join(root, 'app/controllers/posts_controller.rb'))
  end

  it 'does not expose controller methods that are not helper methods' do
    expect(definitions('app/views/posts/show.html.erb', 3, 'load_comments')).to be_empty
  end

  it 'runs views with no matching controller in the application controller\'s view class' do
    layout = 'app/views/layouts/application.html.erb'

    expect(definitions(layout, 1, 'current_user').first&.location&.filename)
      .to eq(File.join(root, 'app/controllers/concerns/authentication.rb'))
    expect(definitions(layout, 1, 'link_to').first&.path).to eq('ActionView::Helpers::UrlHelper#link_to')
    expect(definitions(layout, 1, 'page_title')).to be_empty
  end

  it 'does not resolve view helpers at the top level of a Ruby file' do
    %w[link_to post_title current_user].each_with_index do |helper, line|
      expect(definitions('lib/plain.rb', line, helper)).to be_empty, helper
    end
  end

  it 'resolves ivars assigned in actions and before_action callbacks, with their type' do
    pins = definitions('app/views/posts/show.html.erb', 4, '@post')

    expect(pins.map { |pin| [File.basename(pin.location.filename), pin.location.range.start.line] })
      .to eq([['posts_controller.rb', 9], ['posts_controller.rb', 15]])
    expect(pins.map { |pin| pin.return_type.to_s }.uniq).to eq(['Post'])
  end

  it 'types ivars assigned from private controller methods' do
    pin = definitions('app/views/posts/show.html.erb', 4, '@comments').first

    expect(pin.return_type.to_s).to eq('Array<String>')
  end

  it 'resolves ivars of parent controllers' do
    pin = definitions('app/views/posts/show.html.erb', 4, '@locale').first

    expect(pin.location.filename).to eq(File.join(root, 'app/controllers/application_controller.rb'))
    expect(pin.return_type.to_s).to eq('Symbol')
  end

  it 'does not resolve ivars of other controllers' do
    expect(definitions('app/views/comments/index.html.erb', 0, '@post')).to be_empty
    expect(definitions('app/views/comments/index.html.erb', 0, '@locale')).not_to be_empty
  end

  it 'gives views with no matching controller the application controller\'s ivars only' do
    layout = 'app/views/layouts/application.html.erb'

    expect(definitions(layout, 2, '@locale').first&.return_type.to_s).to eq('Symbol')
    expect(definitions(layout, 2, '@post')).to be_empty
  end
end
