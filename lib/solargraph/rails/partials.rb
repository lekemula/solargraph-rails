module Solargraph
  module Rails
    # The locals of partials (`app/views/**/_name.*.erb`), as parameters of the method a partial's Ruby runs in.
    #
    # A partial with a strict locals comment declares its locals. Otherwise its locals are the names its call sites
    # pass: every `render` of it in a view or controller. Either way the call sites type the locals.
    #
    # The call sites come from an index of the `render` calls in each view and controller. It is filled from disk when
    # a partial is first mapped, so it does not depend on the order files are mapped in, and kept fresh by every
    # source map of a view or controller (see Views#local).
    class Partials
      # ActionView::Template::STRICT_LOCALS_REGEX
      STRICT_LOCALS = /\#\s+locals:\s+\((.*)\)/.freeze
      NAME_TYPES = %i[sym str].freeze

      # The expression a `render` passes as a partial's local.
      class CallSite
        # @return [Solargraph::Location] where the local is named, e.g. the `post:` key of `locals: { post: @post }`
        attr_reader :location

        # @param location [Solargraph::Location]
        # @param node [::Parser::AST::Node] the local's value
        # @param collection [Boolean] whether the value is a collection whose elements are the local
        # @param type [String, nil] the local's type, when it does not depend on the value
        def initialize(location, node, collection: false, type: nil)
          @location = location
          @node = node
          @collection = collection
          @type = type
        end

        # @param api_map [Solargraph::ApiMap]
        # @return [Solargraph::ComplexType]
        def infer(api_map)
          return Solargraph::ComplexType.parse(@type) if @type

          source_map = api_map.source_map(location.filename)
          start = Solargraph::Range.from_node(@node).start
          closure = source_map.locate_closure_pin(start.line, start.character)
          locals = source_map.locals_at(Solargraph::Location.new(location.filename, Solargraph::Range.new(start, start)))
          type = Solargraph::Parser.chain(@node, location.filename).infer(api_map, closure, locals)
          @collection ? element_type(api_map, type) : type
        rescue Solargraph::FileNotFoundError
          Solargraph::ComplexType::UNDEFINED
        end

        private

        # What the collection's `first` returns: an Array's type parameter, or the model of a relation, whose
        # element type comes from the query methods it mixes in rather than a type parameter.
        #
        # @param api_map [Solargraph::ApiMap]
        # @param type [Solargraph::ComplexType]
        # @return [Solargraph::ComplexType]
        def element_type(api_map, type)
          return type if type.undefined?

          first = Solargraph::Source::Chain.new([Solargraph::Source::Chain::Call.new('first')])
          first.infer(api_map, Solargraph::Pin::ProxyType.anonymous(type, source: :solargraph_rails), []).without_nil
        end
      end

      # A partial's local. Its location may be a call site in another file, but it is visible in the partial.
      class Local < Solargraph::Pin::Parameter
        # @return [Array<CallSite>]
        attr_reader :call_sites

        # @param call_sites [Array<CallSite>]
        # @param splat [Hash{Symbol => Object}] Pin::Parameter attributes
        def initialize(call_sites: [], **splat)
          super(**splat)
          @call_sites = call_sites
        end

        def visible_at?(other_closure, other_loc)
          closure.location.filename == other_loc.filename && visible_in_closure?(other_closure)
        end

        # The default value's type and the types the call sites pass.
        def probe(api_map)
          types = [super, *call_sites.map { |site| site.infer(api_map) }].reject(&:undefined?)
          types.empty? ? Solargraph::ComplexType::UNDEFINED : Solargraph::ComplexType.new(types.flat_map(&:items).uniq)
        end
      end

      # @return [Partials]
      def self.instance
        @instance ||= new
      end

      # @param filename [String]
      # @return [Boolean]
      def self.partial?(filename)
        File.basename(filename).start_with?('_')
      end

      def initialize
        @mutex = Mutex.new
        # @type [Hash{String => Array(String, Array<Array(String, String, CallSite)>)}]
        @renders = {}
        @seeded = {}
      end

      # @param source [Solargraph::Source] a transformed view
      # @param render [Solargraph::Pin::Method] the method the view runs in
      # @return [Array<Solargraph::Pin::Parameter>]
      def parameters(source, render)
        return [] unless self.class.partial?(source.filename)

        call_sites = call_sites(source.filename)
        declared = strict_locals(source)
        if declared
          declared.map do |param|
            local(render, param.name, call_sites.fetch(param.name, []),
                  decl: param.decl, asgn_code: param.asgn_code, assignment: param.assignment,
                  location: param.location)
          end
        else
          call_sites.map do |name, sites|
            local(render, name, sites, decl: :kwarg, location: sites.first.location)
          end
        end
      end

      # Indexes the `render` calls of a view or controller.
      #
      # @param source [Solargraph::Source]
      # @return [void]
      def observe(source)
        return unless renderer?(source)
        return if @mutex.synchronize { @renders[source.filename]&.first == source.code }

        renders = scan(source)
        @mutex.synchronize { @renders[source.filename] = [source.code, renders] }
      end

      private

      # @param render [Solargraph::Pin::Method]
      # @param name [String]
      # @param call_sites [Array<CallSite>]
      # @param attrs [Hash{Symbol => Object}] Pin::Parameter attributes
      # @return [Local]
      def local(render, name, call_sites, **attrs)
        Local.new(name: name, closure: render, call_sites: call_sites, source: :solargraph_rails, **attrs)
      end

      # Rails compiles a strict locals comment into the template method's signature
      # (`def _render_template_...(local_assigns, output_buffer, post:, compact: false)`), so its parameters are
      # mapped from a method definition written over the comment, at the comment's positions.
      #
      # @param source [Solargraph::Source]
      # @return [Array<Solargraph::Pin::Parameter>, nil] nil when the partial has no strict locals comment
      def strict_locals(source)
        match = STRICT_LOCALS.match(source.original_code)
        return unless match

        code = source.original_code.gsub(/[^\r\n]/, ' ')
        open = match.begin(1) - 1
        code[open - 5, 5] = 'def _'
        code[open, match.end(1) - open + 1] = "(#{match[1]})"
        pins, = Solargraph::Parser.map(Solargraph::Source.new("#{code}\nend", source.filename))
        pins.find { |pin| pin.is_a?(Solargraph::Pin::Method) && pin.name == '_' }&.parameters || []
      end

      # @param filename [String] a partial
      # @return [Hash{String => Array<CallSite>}]
      def call_sites(filename)
        root, path = split_view(filename)
        seed(root)
        renders = @mutex.synchronize do
          @renders.select { |file, _| file.start_with?("#{root}/") }.values.flat_map(&:last)
        end
        renders.select { |target, _, _| target == path }
               .sort_by { |_, _, site| [site.location.filename, site.location.range.start.line] }
               .group_by { |_, name, _| name }
               .transform_values { |matches| matches.map(&:last) }
      end

      # @param filename [String]
      # @return [Array(String, String)] the app root, and the partial's path as `render` names it, e.g. 'posts/card'
      def split_view(filename)
        root = filename[0...filename.rindex('/app/views/')]
        dir, base = File.split(filename.delete_prefix("#{root}/app/views/"))
        [root, File.join(dir, base.delete_prefix('_').split('.').first)]
      end

      # Indexes the views and controllers of an app from disk, for those not mapped yet.
      #
      # @param root [String]
      # @return [void]
      def seed(root)
        return if @mutex.synchronize { @seeded[root] }

        files = Dir[File.join(root, 'app/views/**/*.erb')] + Dir[File.join(root, 'app/controllers/**/*_controller.rb')]
        files.each do |file|
          next if @mutex.synchronize { @renders.key?(file) }

          code = File.read(file)
          observe(Solargraph::Source.load_string(code, file)) if code.include?('render')
        end
        @mutex.synchronize { @seeded[root] = true }
      end

      # @param source [Solargraph::Source]
      # @return [Boolean]
      def renderer?(source)
        filename = source.filename.to_s
        return source.transformed? if Views.view?(filename)

        filename.include?('/app/controllers/') && filename.end_with?('_controller.rb')
      end

      # @param source [Solargraph::Source]
      # @return [Array<Array(String, String, CallSite)>] the partial path, local name and call site of each local
      def scan(source)
        controller = !Views.view?(source.filename)
        dir = rendering_dir(source.filename, controller)
        renders = []
        walker = Walker.from_source(source)
        walker.on :send, [nil, :render] do |node|
          renders.concat render_locals(source.filename, dir, node, controller)
        end
        walker.walk
        renders
      end

      # The directory a partial name without a slash is looked up in: the view's, or the controller's
      # `controller_path`. Rails looks there first (ActionView::PartialRenderer#find_template uses the lookup
      # context's prefixes for a name without a slash); the prefixes of parent controllers are not followed.
      #
      # @param filename [String]
      # @param controller [Boolean]
      # @return [String]
      def rendering_dir(filename, controller)
        if controller
          filename[(filename.rindex('/app/controllers/') + 17)..].delete_suffix('_controller.rb')
        else
          File.dirname(filename[(filename.rindex('/app/views/') + 11)..])
        end
      end

      # Rails' render forms, from ActionView::Helpers::RenderingHelper#render (views) and
      # ActionView::Rendering#_normalize_args (controllers):
      #
      # - `render "post", post: @post`: a partial and its locals, in views. In controllers a string is a template.
      # - `render partial: "posts/summary", locals: { ... }, collection: ..., object: ..., as: ...`
      # - `render @posts, locals`: a partial for each element, at the element's `to_partial_path`.
      #
      # @param filename [String]
      # @param dir [String]
      # @param node [::Parser::AST::Node]
      # @param controller [Boolean]
      # @return [Array<Array(String, String, CallSite)>]
      def render_locals(filename, dir, node, controller)
        first, second = node.children[2..]
        return [] if first.nil? || (controller && first.type == :str)

        options = first.type == :hash ? options(first) : { partial: first, locals: second }
        partial = options[:partial]
        return [] if partial.nil?

        if partial.type == :str
          path = partial_path(partial.children.first, dir)
          object = options[:collection] || options[:object]
          collection = !options[:collection].nil?
        else
          path = object_path(partial)
          object = partial
          collection = plural?(partial)
        end
        return [] unless path

        variable = (options[:as] && name_of(options[:as])) || local_name(path)
        locals = hash_locals(filename, options[:locals])
        locals += object_locals(filename, object, variable, collection) if object
        locals.map { |name, site| [path, name, site] }
      end

      # `render @posts`: Rails renders each element at its `to_partial_path`, `posts/post` for a Post
      # (ActiveModel::Conversion#to_partial_path). Without types, the element is named after the expression:
      # `@posts`, `posts` and `user.posts` render `posts/_post`.
      #
      # @param node [::Parser::AST::Node]
      # @return [String, nil]
      def object_path(node)
        name = expression_name(node)
        return unless name

        singular = name.singularize
        "#{singular.pluralize}/#{singular}"
      end

      # @param node [::Parser::AST::Node]
      # @return [Boolean] whether the expression is named like a collection
      def plural?(node)
        name = expression_name(node)
        !name.nil? && name != name.singularize
      end

      # A collection gives each element's partial `post`, `post_counter` and `post_iteration`
      # (ActionView::CollectionRenderer#retrieve_variable, typed in #render_collection); an object gives `post`.
      #
      # @param filename [String]
      # @param node [::Parser::AST::Node] the rendered object or collection
      # @param variable [String]
      # @param collection [Boolean]
      # @return [Array<Array(String, CallSite)>]
      def object_locals(filename, node, variable, collection)
        location = Solargraph::Location.new(filename, Solargraph::Range.from_node(node))
        locals = [[variable, CallSite.new(location, node, collection: collection)]]
        return locals unless collection

        locals + [
          ["#{variable}_counter", CallSite.new(location, node, type: 'Integer')],
          ["#{variable}_iteration", CallSite.new(location, node, type: 'ActionView::PartialIteration')]
        ]
      end

      # @param node [::Parser::AST::Node]
      # @return [String, nil]
      def expression_name(node)
        case node.type
        when :ivar, :lvar then node.children.first.to_s.delete_prefix('@')
        when :send then node.children[1].to_s
        end
      end

      # @param filename [String]
      # @param node [::Parser::AST::Node, nil]
      # @return [Array<Array(String, CallSite)>]
      def hash_locals(filename, node)
        return [] unless node&.type == :hash

        node.children.filter_map do |pair|
          next unless pair.type == :pair && NAME_TYPES.include?(pair.children[0].type)

          key, value = pair.children
          name = key.children.first.to_s
          start = Solargraph::Range.from_node(key).start
          range = Solargraph::Range.from_to(start.line, start.character, start.line, start.character + name.length)
          [name, CallSite.new(Solargraph::Location.new(filename, range), value)]
        end
      end

      # @param node [::Parser::AST::Node]
      # @return [Hash{Symbol => ::Parser::AST::Node}]
      def options(node)
        node.children.each_with_object({}) do |pair, options|
          next unless pair.type == :pair && pair.children[0].type == :sym

          options[pair.children[0].children.first] = pair.children[1]
        end
      end

      # A name without a slash is relative to the rendering view (ActionView::PartialRenderer#find_template).
      #
      # @param name [String]
      # @param dir [String]
      # @return [String]
      def partial_path(name, dir)
        name.include?('/') ? name : File.join(dir, name)
      end

      # The local a partial names, after the partial: ActionView::AbstractRenderer#local_variable.
      #
      # @param path [String]
      # @return [String]
      def local_name(path)
        File.basename(path).delete_prefix('_').split('.').first
      end

      # @param node [::Parser::AST::Node] a symbol or string
      # @return [String, nil]
      def name_of(node)
        node.children.first.to_s if NAME_TYPES.include?(node.type)
      end
    end
  end
end
