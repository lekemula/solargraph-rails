module Solargraph
  module Rails
    class Rspec
      # @return [Rspec]
      def self.instance
        @instance ||= new
      end

      # @param filename [String]
      # @return [Boolean]
      def self.valid_filename?(filename)
        filename.include?('spec/')
      end

      # @param source_map [SourceMap]
      # @param ns [Pin::Namespace, nil]
      # @return [Array<Pin::Base>]
      def process(source_map, _ns)
        Solargraph.logger.debug "[Rails][RSpec] processing #{source_map.filename}"

        return [] unless self.class.valid_filename?(source_map.filename)

        walker = Walker.from_source(source_map.source)
        # @type [Array<Pin::Base>]
        pins = []
        # @type [Array<Pin::Namespace>]
        namespace_pins = []
        # @type [Array<Pin::Block>]
        block_pins = []

        each_rspec_block(walker.ast, "RSpec::ExampleGroups") do |namespace_name, ast|
          location = Util.build_location(ast, source_map.filename)
          namespace_pin = Solargraph::Pin::Namespace.new(
            name: namespace_name,
            location: location
          )

          block_pin = Solargraph::Pin::Block.new(
            closure: namespace_pin,
            location: location,
          )
 
          namespace_pins << namespace_pin
          block_pins << block_pin
        end
        pins += namespace_pins
        pins += block_pins

        rspec_const = ::Parser::AST::Node.new(:const, [nil, :RSpec])
        walker.on :send, [rspec_const, :describe, :any] do |ast|
          namespace_pin = closest_namespace_pin(namespace_pins, ast.loc.line)

          pin = rspec_described_class_method(namespace_pin, ast)
          pins << pin unless pin.nil?
        end

        walker.on :send, [nil, :let] do |ast|
          namespace_pin = closest_namespace_pin(namespace_pins, ast.loc.line)

          pin = rspec_let_method(namespace_pin, ast)
          pins << pin unless pin.nil?
        end

        walker.on :send, [nil, :subject] do |ast|
          namespace_pin = closest_namespace_pin(namespace_pins, ast.loc.line)

          pin = rspec_let_method(namespace_pin, ast)
          pins << pin unless pin.nil?
        end

        walker.walk
        if pins.any?
          Solargraph.logger.debug(
            "[Rails][RSpec] added #{pins.map(&:inspect)} to #{source_map.filename}"
          )
        end
        pins
      end

      private

      # @param namespace_pins [Array<Pin::Namespace>]
      # @param line [Integer]
      # @return [Pin::Namespace]
      def closest_namespace_pin(namespace_pins, line)
        namespace_pins.sort_by do |namespace_pin|
          distance = line - namespace_pin.location.range.start.line
          distance > 0 ? distance : Float::INFINITY
        end.first
      end

      # @param ast [Parser::AST::Node]
      # @yield [String, Parser::AST::Node]
      def each_rspec_block(ast, parent_namespace = "RSpec::ExampleGroups", &block)
        return unless ast.is_a?(::Parser::AST::Node)
        is_a_block = ast.type == :block && ast.children[0].type == :send
        is_a_context = is_a_block && [:describe, :context].include?(ast.children[0].children[1])
        namespace_name = parent_namespace

        if is_a_context
          description_node = ast.children[0].children[2]
          namespace_name = parent_namespace + "::" + rspec_describe_class_name(description_node)
          block.call(namespace_name, ast) if block
        end

        ast.children.each { |child| each_rspec_block(child, namespace_name, &block) }
      end

      # @param namespace [Pin::Namespace]
      # @param ast [Parser::AST::Node]
      # @return [Pin::Method, nil]
      def rspec_let_method(namespace, ast)
        return unless ast.children
        return unless ast.children[2]&.children
        method_name = ast.children[2].children[0]&.to_s or return

        Util.build_public_method(
          namespace,
          method_name,
          location: Util.build_location(ast, namespace.filename),
          scope: :class # TODO: Make it work with :instance like RSpec declares it
        )
      end

      # @param ast [Parser::AST::Node]
      # @return [String]
      def rspec_describe_class_name(ast)
        if ast.type == :str
          string_to_const_name(ast)
        elsif ast.type == :const
          full_constant_name(ast).gsub('::', '')
        else
          raise "Unexpected AST type #{ast.type}"
        end
      end

      # @param namespace [Pin::Namespace]
      # @param ast [Parser::AST::Node]
      # @return [Pin::Method, nil]
      def rspec_described_class_method(namespace, ast)
        class_ast = ast.children[2]
        return unless class_ast.type == :const

        class_name = full_constant_name(class_ast)
        rspec_example_group = "RSpec::ExampleGroups::#{rspec_describe_class_name(ast.children[2])}"

        Util.build_public_method(
          namespace,
          'described_class',
          types: ["Class<#{class_name}>"],
          location: Util.build_location(class_ast, namespace.filename),
          scope: :class # TODO: Make it work with :instance like RSpec declares it
        )
      end

      # @param ast [Parser::AST::Node]
      # @return [String]
      def full_constant_name(ast)
        raise 'Node is not a constant' unless ast.type == :const

        name = ast.children[1].to_s
        if ast.children[0].nil?
          name
        else
          "#{full_constant_name(ast.children[0])}::#{name}"
        end
      end

      # @param ast [Parser::AST::Node]
      # @return [String]
      def string_to_const_name(string_ast)
        return unless string_ast.type == :str
        string = string_ast.children[0]
        string.split(/\W+/).map(&:capitalize).join
      end
    end
  end
end
