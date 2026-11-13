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

  describe 'partial locals' do
    it 'declares strict locals as locals defined in the magic comment' do
      pin = definitions('app/views/posts/_card.html.erb', 1, 'post').first

      expect(pin.name).to eq('post')
      expect(pin.location.filename).to eq(File.join(root, 'app/views/posts/_card.html.erb'))
      expect([pin.location.range.start.line, pin.location.range.start.character]).to eq([0, 13])
    end

    it 'types a strict local with a default value from the default' do
      expect(definitions('app/views/posts/_card.html.erb', 1, 'compact').first.return_type.to_s).to eq('Boolean')
    end

    it 'types a strict local from the call sites that pass it' do
      expect(definitions('app/views/posts/_card.html.erb', 1, 'post').first.return_type.to_s).to eq('Post')
    end

    it 'ignores locals a call site passes that the strict locals do not declare' do
      expect(definitions('app/views/posts/_card.html.erb', 2, 'ignored')).to be_empty
    end

    it 'declares the locals every call site passes with locals:' do
      controller = File.join(root, 'app/controllers/previews_controller.rb')
      post, author = %w[post author].map { |name| definitions('app/views/posts/_summary.html.erb', 0, name).first }

      expect(post.return_type.to_s).to eq('Post')
      expect(author.return_type.to_s).to eq('User')
      expect(author.location.filename).to eq(controller)
      expect([author.location.range.start.line, author.location.range.start.character])
        .to eq([2, File.readlines(controller)[2].index('author:')])
      expect(post.location.filename).to eq(File.join(root, 'app/views/posts/feed.html.erb'))
    end

    it 'declares the element, counter and iteration of a rendered collection' do
      partial = 'app/views/posts/_post.html.erb'
      types = %w[post post_counter post_iteration].map do |name|
        definitions(partial, 0, name).first&.return_type.to_s
      end

      expect(types).to eq(%w[Post Integer ActionView::PartialIteration])
      expect(definitions(partial, 0, 'post').first.location.filename).to eq(File.join(root, 'app/views/posts/feed.html.erb'))
    end

    it 'renders a collection at the partial path its elements are named after' do
      partial = 'app/views/comments/_comment.html.erb'

      expect(definitions(partial, 0, 'comment').first.location.range.start.line).to eq(2)
      expect(definitions(partial, 0, 'comment_counter')).not_to be_empty
    end

    it 'gives a view that is not a partial no locals' do
      expect(definitions('app/views/posts/index.html.erb', 1, 'post')).to be_empty
    end

    it 'still runs a partial with a malformed strict locals comment in its view class' do
      expect(definitions('app/views/posts/_broken.html.erb', 1, 'link_to').first&.path)
        .to eq('ActionView::Helpers::UrlHelper#link_to')
    end

    it 'types the locals of a partial that renders itself from its other call sites' do
      expect(definitions('app/views/posts/_tree.html.erb', 0, 'node').first.return_type.to_s).to eq('Integer')
    end

    it 'indexes the call sites of a view again when it changes' do
      feed = File.join(root, 'app/views/posts/feed.html.erb')
      partial = Solargraph::Source.load(File.join(root, 'app/views/posts/_tree.html.erb'))

      Solargraph::Rails::Partials.instance.observe(Solargraph::Source.load_string('<%= render "tree", depth: 1 %>', feed))
      expect(described_class.instance.source_closure(partial).parameters.map(&:name)).to include('depth')
    ensure
      Solargraph::Rails::Partials.instance.observe(Solargraph::Source.load(feed))
    end
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
