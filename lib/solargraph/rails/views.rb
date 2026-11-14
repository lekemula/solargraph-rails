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
    # `PostsControllerView#__render`. A partial outside a controller's folder runs for the controllers whose views or
    # actions render it, directly or through other partials: in that controller's view class, or in a view class of
    # its own holding all their instance variables when there are several. Any other view (layouts, unrendered
    # partials, mailer views) runs in `ApplicationControllerView#__render`.
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

        Partials.instance.observe(source_map.source)
        return view_environ(source_map.filename) if self.class.view?(source_map.filename) && source_map.source.transformed?
        return controller_environ(source_map) if source_map.filename.to_s.include?('/app/controllers/')

        Solargraph::Environ.new
      end

      # The `helper_method` targets of a view class's controller, or of the controllers a partial's view class renders
      # for, as methods of the view class. A target may be defined in a parent controller or a concern, so it is
      # looked up on the controller when methods are queried.
      #
      # @param api_map [Solargraph::ApiMap]
      # @param rooted_tag [String]
      # @param scope [Symbol]
      # @return [Array<Solargraph::Pin::Method>]
      def object(api_map, rooted_tag, scope)
        return [] unless self.class.supported? && scope == :instance

        fqns = rooted_tag.delete_prefix('::').split('<').first.to_s
        controllers = fqns.end_with?('ControllerView') ? [fqns.delete_suffix('View')] : partial_controllers[fqns]
        return [] unless controllers

        view_class = api_map.get_path_pins(fqns).find { |pin| pin.is_a?(Solargraph::Pin::Namespace) }
        return [] unless view_class

        controllers.flat_map { |controller| helper_method_pins(api_map, controller, view_class) }
      end

      private

      # @param api_map [Solargraph::ApiMap]
      # @param controller [String]
      # @param view_class [Solargraph::Pin::Namespace]
      # @return [Array<Solargraph::Pin::Method>]
      def helper_method_pins(api_map, controller, view_class)
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

      # @return [Hash{String => Array<String>}] the controllers each partial view class renders for
      def partial_controllers
        @partial_controllers ||= {}
      end

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

      # @param filename [String]
      # @return [Solargraph::Environ]
      def view_environ(filename)
        pins = partial_view_class_pins(filename) + Partials.instance.targets(filename)
        Solargraph::Environ.new(requires: %w[action_view action_controller], pins: pins)
      end

      # A partial rendered for several controllers runs in a view class of its own, holding all their instance
      # variables. A class has one superclass and Solargraph looks instance variables up its superclasses only, so
      # it copies them, like a controller's view class does.
      #
      # @param filename [String]
      # @return [Array<Solargraph::Pin::Base>]
      def partial_view_class_pins(filename)
        return [] if folder_controller(filename)

        controllers = renderer_controllers(filename)
        return [] if controllers.size < 2

        view_class = Solargraph::Pin::Namespace.new(
          name: partial_view_class(filename), closure: Solargraph::Pin::ROOT_PIN,
          location: Solargraph::Location.new(filename, Solargraph::Range.from_to(0, 0, 0, 0))
        )
        partial_controllers[view_class.path] = controllers
        superclass = Solargraph::Pin::Reference::Superclass.new(name: ROOT_VIEW_CLASS, closure: view_class)
        ivars = controllers.flat_map { |controller| ivars_of(app_root(filename, 'app/views'), controller) }
        [view_class, superclass, *assign_pins(ivars, view_class)]
      end

      # @param filename [String] a partial, e.g. app/views/shared/_flash.html.erb
      # @return [String] e.g. 'SharedFlashPartialView'
      def partial_view_class(filename)
        root = app_root(filename, 'app/views')
        dir, base = File.split(filename.delete_prefix(File.join(root, 'app/views/')))
        "#{File.join(dir, base.delete_prefix('_').split('.').first).camelize.delete(':')}PartialView"
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
        ivars = recorded_ivars[controller.path] = controller_ivars(controller.path, source_map.pins, source_map.source)
        assign_pins(ivars, view_class)
      end

      # @param ivars [Array<Array(Solargraph::Pin::InstanceVariable, Boolean)>] each with whether a callback assigns it
      # @param view_class [Solargraph::Pin::Namespace]
      # @return [Array<Solargraph::Pin::Base>]
      def assign_pins(ivars, view_class)
        return [] if ivars.empty?

        # A bodyless method gives the copies an instance binder in the view class
        holder = Solargraph::Pin::Method.new(
          name: '__assigns', closure: view_class, scope: :instance, visibility: :private, location: view_class.location
        )
        [holder, *ivars.map do |ivar, callback|
          Assign.new(
            origins: [ivar], callback: callback, name: ivar.name, closure: holder,
            location: ivar.location, comments: ivar.comments
          )
        end]
      end

      # @param controller [String]
      # @param pins [Array<Solargraph::Pin::Base>] the pins of the controller's file
      # @param source [Solargraph::Source]
      # @return [Array<Array(Solargraph::Pin::InstanceVariable, Boolean)>] each with whether a callback assigns it
      def controller_ivars(controller, pins, source)
        callbacks = callback_names(source)
        pins.filter_map do |pin|
          next unless pin.is_a?(Solargraph::Pin::InstanceVariable) && pin.scope == :instance &&
                      pin.binder.namespace == controller

          [pin, callbacks.include?(pin.closure&.name)]
        end
      end

      # The instance variables of each controller, as its last source map found them, for the view classes of the
      # partials its views render.
      #
      # @return [Hash{String => Array<Array(Solargraph::Pin::InstanceVariable, Boolean)>}]
      def recorded_ivars
        @recorded_ivars ||= {}
      end

      # A controller's instance variables, from its last source map or, before it is mapped, from its file.
      #
      # @param root [String]
      # @param controller [String]
      # @return [Array<Array(Solargraph::Pin::InstanceVariable, Boolean)>]
      def ivars_of(root, controller)
        recorded_ivars.fetch(controller) do
          file = File.join(root, 'app/controllers', "#{controller.underscore}.rb")
          next [] unless File.exist?(file)

          source = Solargraph::Source.load(file)
          recorded_ivars[controller] = controller_ivars(controller, Solargraph::Parser.map(source).first, source)
        end
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

      # app/views/admin/posts/show.html.erb runs in Admin::PostsControllerView, when the app has that controller. A
      # partial outside a controller's folder runs in the view class of the controller whose views render it, or in a
      # view class of its own when several controllers' views do (see #partial_view_class_pins).
      #
      # @param filename [String]
      # @return [String]
      def view_class_for(filename)
        controller = folder_controller(filename)
        return self.class.view_class(controller) if controller

        controllers = renderer_controllers(filename)
        return ROOT_VIEW_CLASS if controllers.empty?
        return self.class.view_class(controllers.first) if controllers.one?

        partial_view_class(filename)
      end

      # @param filename [String] a view
      # @return [String, nil] the controller whose folder the view is in, e.g. 'Admin::PostsController'
      def folder_controller(filename)
        root = app_root(filename, 'app/views')
        dir = File.dirname(filename.delete_prefix(File.join(root, 'app/views/')))
        "#{dir}_controller".camelize if File.exist?(File.join(root, 'app/controllers', "#{dir}_controller.rb"))
      end

      # The controllers a partial outside a controller's folder renders for: those whose views or actions render it,
      # directly or through other such partials.
      #
      # @param filename [String] a view
      # @param seen [Set<String>] the views already followed
      # @return [Array<String>]
      def renderer_controllers(filename, seen = Set[filename])
        return [] unless Partials.partial?(filename)

        Partials.instance.renderers(filename).flat_map do |renderer|
          next [] unless seen.add?(renderer)
          next [renderer.split('/app/controllers/').last.delete_suffix('.rb').camelize] unless self.class.view?(renderer)

          controller = folder_controller(renderer)
          controller ? [controller] : renderer_controllers(renderer, seen)
        end.uniq.sort
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
