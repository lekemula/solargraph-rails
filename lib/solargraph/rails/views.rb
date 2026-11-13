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
        Solargraph::Pin::Method.new(
          name: '__render',
          closure: view_class,
          scope: :instance,
          visibility: :private,
          location: source.location,
          node: source.node
        )
      end

      # @param source_map [Solargraph::SourceMap]
      # @return [Solargraph::Environ]
      def local(source_map)
        return Solargraph::Environ.new unless self.class.supported?
        return view_environ if self.class.view?(source_map.filename) && source_map.source.transformed?
        return controller_environ(source_map) if source_map.filename.to_s.include?('/app/controllers/')

        Solargraph::Environ.new
      end

      private

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
        if superclass.nil? || BASE_CONTROLLERS.include?(superclass.name.delete_prefix('::'))
          [
            view_class,
            Solargraph::Pin::Reference::Superclass.new(name: '::ActionView::Base', closure: view_class),
            *helper_modules(source_map.filename).map do |name|
              Solargraph::Pin::Reference::Include.new(name: name, closure: view_class)
            end
          ]
        else
          [
            view_class,
            Solargraph::Pin::Reference::Superclass.new(
              name: self.class.view_class(superclass.name), closure: view_class
            )
          ]
        end
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
