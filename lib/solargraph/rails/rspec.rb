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
        pins = []

        rspec_const = ::Parser::AST::Node.new(:const, [nil, :RSpec])
        walker.on :send, [rspec_const, :describe, :any] do |ast|
          pin = described_class_method(source_map.filename, ast)
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

      # @param filename [String]
      # @param ast [Parser::AST::Node]
      # @return [Pin::Method]
      def described_class_method(filename, ast)
        class_ast = ast.children[2]
        return unless class_ast.type == :const

        class_name = full_constant_name(ast.children[2])
        rspec_example_group = "RSpec::ExampleGroups::#{class_name.gsub('::', '')}"

        Util.build_public_method(
          Solargraph::Pin::Namespace.new(name: ''),
          'described_class',
          types: ["Class<#{class_name}>"],
          location: Util.build_location(class_ast, filename)
        )
      end

      # @param ast [Parser::AST::Node]
      def full_constant_name(ast)
        raise 'Node is not a constant' unless ast.type == :const

        name = ast.children[1].to_s
        if ast.children[0].nil?
          name
        else
          "#{full_constant_name(ast.children[0])}::#{name}"
        end
      end
    end
  end
end
