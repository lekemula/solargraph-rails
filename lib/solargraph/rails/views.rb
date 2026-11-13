module Solargraph
  module Rails
    # Runs the Ruby of an ERB view (transformed by e.g. solargraph-herb) in a view context class, the way Rails
    # renders a template in its controller's `view_context_class`.
    #
    # Each controller contributes a view class that mirrors its inheritance:
    #
    #   PostsControllerView < ApplicationControllerView < ActionView::Base
    #
    # The root view class includes every app helper module. A view under `app/views/posts/` runs in
    # `PostsControllerView#__render`; a view with no matching controller (layouts, shared partials, mailer views)
    # runs in `ApplicationControllerView#__render`.
    class Views
      ROOT_VIEW_CLASS = 'ApplicationControllerView'.freeze
      BASE_CONTROLLERS = %w[ActionController::Base ActionController::API].freeze
      CALLBACKS = %i[before_action prepend_before_action append_before_action].freeze

      # A controller instance variable copied into its view class. It keeps the assignment's location, and infers
      # its type in the controller, where methods like a private `load_comments` exist.
      class Assign < Solargraph::Pin::InstanceVariable
        # @return [Array<Solargraph::Pin::InstanceVariable>] the controller's instance variables this copies
        attr_reader :origins

        # @return [Boolean] whether a before_action callback assigns it
        attr_reader :callback

        # @param origins [Array<Solargraph::Pin::InstanceVariable>]
        # @param callback [Boolean]
        # @param splat [Hash] the instance variable's attributes
        def initialize(origins: [], callback: false, **splat)
          super(**splat)
          @origins = origins
          @callback = callback
        end

        # Solargraph merges every assignment a reference can see into one pin, which must keep all their origins.
        # Its location is a callback's assignment if there is one, since callbacks run for most actions, else the
        # first assignment.
        #
        # @param other [Solargraph::Pin::InstanceVariable]
        # @param attrs [Hash]
        # @return [Solargraph::Pin::InstanceVariable]
        def combine_with(other, attrs = {})
          other_callback = other.is_a?(Assign) && other.callback
          merged = {
            origins: origins + (other.is_a?(Assign) ? other.origins : [other]),
            callback: callback || other_callback
          }
          merged[:location] = callback ? location : other.location unless callback == other_callback
          super(other, attrs.merge(merged))
        end

        # @param api_map [Solargraph::ApiMap]
        # @return [Solargraph::ComplexType]
        def probe(api_map)
          return super if origins.empty?

          types = origins.map { |origin| origin.probe(api_map) }.reject(&:undefined?)
          return Solargraph::ComplexType::UNDEFINED if types.empty?

          Solargraph::ComplexType.new(types.flat_map(&:items).uniq)
        end
      end

      # Whether Solargraph can bind a transformed source to a closure.
      #
      # @return [Boolean]
      def self.supported?
        Solargraph::Convention::Base.method_defined?(:source_closure)
      end

      # @return [Views]
      def self.instance
        @instance ||= new
      end

      # @param filename [String, nil]
      # @return [Boolean]
      def self.view?(filename)
        !filename.nil? && filename.end_with?('.erb') && filename.include?('/app/views/')
      end

      # @param controller [String] a controller's path, e.g. 'Admin::PostsController'
      # @return [String]
      def self.view_class(controller)
        "#{controller}View"
      end

      # @param source [Solargraph::Source] a transformed source
      # @return [Solargraph::Pin::Method, nil] the method the view's Ruby runs in
      def source_closure(source)
        return unless self.class.supported? && self.class.view?(source.filename)

        view_class = Solargraph::Pin::Namespace.new(
          name: view_class_for(source.filename), closure: Solargraph::Pin::ROOT_PIN
        )
        render = Solargraph::Pin::Method.new(
          name: '__render',
          closure: view_class,
          scope: :instance,
          visibility: :private,
          location: source.location,
          node: source.node
        )
        render.parameters.concat Partials.instance.parameters(source, render)
        render
      end

      # @param source_map [Solargraph::SourceMap]
      # @return [Solargraph::Environ]
      def local(source_map)
        return Solargraph::Environ.new unless self.class.supported?
        return view_environ if self.class.view?(source_map.filename) && source_map.source.transformed?
        return controller_environ(source_map) if source_map.filename.to_s.include?('/app/controllers/')

        Solargraph::Environ.new
      end

      # The `helper_method` targets of a view class's controller, as methods of the view class. A target may be
      # defined in a parent controller or a concern, so it is looked up on the controller when methods are queried.
      #
      # @param api_map [Solargraph::ApiMap]
      # @param rooted_tag [String]
      # @param scope [Symbol]
      # @return [Array<Solargraph::Pin::Method>]
      def object(api_map, rooted_tag, scope)
        return [] unless self.class.supported? && scope == :instance

        fqns = rooted_tag.delete_prefix('::').split('<').first
        return [] unless fqns&.end_with?('ControllerView')

        view_class = api_map.get_path_pins(fqns).find { |pin| pin.is_a?(Solargraph::Pin::Namespace) }
        return [] unless view_class

        controller = fqns.delete_suffix('View')
        helper_method_names(api_map, controller).filter_map do |name|
          target = api_map.get_method_stack(controller, name).first
          next unless target.is_a?(Solargraph::Pin::Method)

          Solargraph::Pin::Method.new(
            name: name,
            closure: view_class,
            scope: :instance,
            visibility: :public,
            location: target.location,
            comments: target.comments,
            node: target.node,
            parameters: target.parameters
          )
        end
      end

      private

      # Names a controller declares with `helper_method`, in its own body or in the modules it includes. Those of its
      # parent controllers belong to the parent's view class.
      #
      # @param api_map [Solargraph::ApiMap]
      # @param controller [String]
      # @return [Array<String>]
      def helper_method_names(api_map, controller)
        namespaces = [controller, *api_map.get_includes(controller).map { |include| api_map.dereference(include) }]
        filenames = namespaces.compact.flat_map do |namespace|
          api_map.get_path_pins(namespace).filter_map { |pin| pin.location&.filename }
        end
        filenames.uniq.select { |filename| api_map.bundled?(filename) }.flat_map do |filename|
          scan_helper_methods(api_map.source_map(filename).source)
        end.uniq
      end

      # @param source [Solargraph::Source]
      # @return [Array<String>]
      def scan_helper_methods(source)
        return [] unless source.code.include?('helper_method')

        @helper_methods ||= {}
        cached = @helper_methods[source.filename]
        return cached[1] if cached && cached[0] == source.code

        names = []
        walker = Walker.from_source(source)
        walker.on :send, [nil, :helper_method] do |ast|
          ast.children[2..].each { |arg| names << arg.children[0].to_s if arg.type == :sym }
        end
        walker.walk
        @helper_methods[source.filename] = [source.code, names]
        names
      end

      # @return [Solargraph::Environ]
      def view_environ
        Solargraph::Environ.new(requires: %w[action_view action_controller])
      end

      # @param source_map [Solargraph::SourceMap]
      # @return [Solargraph::Environ]
      def controller_environ(source_map)
        pins = source_map.pins.select { |pin| controller?(pin) }.flat_map do |controller|
          view_class_pins(source_map, controller)
        end
        Solargraph::Environ.new(pins: pins)
      end

      # @param pin [Solargraph::Pin::Base]
      # @return [Boolean]
      def controller?(pin)
        pin.is_a?(Solargraph::Pin::Namespace) && pin.type == :class && pin.path.end_with?('Controller')
      end

      # @param source_map [Solargraph::SourceMap]
      # @param controller [Solargraph::Pin::Namespace]
      # @return [Array<Solargraph::Pin::Base>]
      def view_class_pins(source_map, controller)
        view_class = Solargraph::Pin::Namespace.new(
          name: self.class.view_class(controller.path),
          closure: Solargraph::Pin::ROOT_PIN,
          location: controller.location
        )
        superclass = source_map.pins.find do |pin|
          pin.is_a?(Solargraph::Pin::Reference::Superclass) && pin.closure == controller
        end
        ancestry = if superclass.nil? || BASE_CONTROLLERS.include?(superclass.name.delete_prefix('::'))
                     [
                       Solargraph::Pin::Reference::Superclass.new(name: '::ActionView::Base', closure: view_class),
                       *helper_modules(source_map.filename).map do |name|
                         Solargraph::Pin::Reference::Include.new(name: name, closure: view_class)
                       end
                     ]
                   else
                     [
                       Solargraph::Pin::Reference::Superclass.new(
                         name: self.class.view_class(superclass.name), closure: view_class
                       )
                     ]
                   end
        [view_class, *ancestry, *assigns(source_map, controller, view_class)]
      end

      # The controller's instance variables, assigned in any of its methods (callbacks included), as instance
      # variables of its view class. A parent controller's reach the view through the parent's view class.
      #
      # @param source_map [Solargraph::SourceMap]
      # @param controller [Solargraph::Pin::Namespace]
      # @param view_class [Solargraph::Pin::Namespace]
      # @return [Array<Solargraph::Pin::Base>]
      def assigns(source_map, controller, view_class)
        ivars = source_map.pins.select do |pin|
          pin.is_a?(Solargraph::Pin::InstanceVariable) && pin.scope == :instance &&
            pin.binder.namespace == controller.path
        end
        return [] if ivars.empty?

        # A bodyless method gives the copies an instance binder in the view class
        holder = Solargraph::Pin::Method.new(
          name: '__assigns', closure: view_class, scope: :instance, visibility: :private, location: controller.location
        )
        callbacks = callback_names(source_map.source)
        [holder, *ivars.map do |ivar|
          Assign.new(
            origins: [ivar], callback: callbacks.include?(ivar.closure&.name), name: ivar.name, closure: holder,
            location: ivar.location, comments: ivar.comments
          )
        end]
      end

      # @param source [Solargraph::Source] a controller's source
      # @return [Array<String>] the methods its before_action callbacks name
      def callback_names(source)
        return [] unless source.code.include?('before_action')

        names = []
        walker = Walker.from_source(source)
        CALLBACKS.each do |callback|
          walker.on :send, [nil, callback] do |ast|
            ast.children[2..].each { |arg| names << arg.children[0].to_s if arg.type == :sym }
          end
        end
        walker.walk
        names
      end

      # Rails includes every helper module into every view by default (`include_all_helpers`).
      #
      # @param filename [String] a controller's file
      # @return [Array<String>]
      def helper_modules(filename)
        helpers = File.join(app_root(filename, 'app/controllers'), 'app/helpers')
        Dir[File.join(helpers, '**/*_helper.rb')].sort.map do |path|
          path.delete_prefix("#{helpers}/").delete_suffix('.rb').camelize
        end
      end

      # app/views/admin/posts/show.html.erb runs in Admin::PostsControllerView, when the app has that controller.
      #
      # @param filename [String]
      # @return [String]
      def view_class_for(filename)
        root = app_root(filename, 'app/views')
        dir = File.dirname(filename.delete_prefix(File.join(root, 'app/views/')))
        return ROOT_VIEW_CLASS unless File.exist?(File.join(root, 'app/controllers', "#{dir}_controller.rb"))

        self.class.view_class("#{dir}_controller".camelize)
      end

      # @param filename [String]
      # @param dir [String] the app directory the file is in, e.g. 'app/views'
      # @return [String]
      def app_root(filename, dir)
        filename[0...filename.rindex("/#{dir}/")]
      end
    end
  end
end
