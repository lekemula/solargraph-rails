module Solargraph
  module Rails
    # The locals of partials (`app/views/**/_name.*.erb`), as parameters of the method a partial's Ruby runs in.
    class Partials
      # ActionView::Template::STRICT_LOCALS_REGEX
      STRICT_LOCALS = /\#\s+locals:\s+\((.*)\)/.freeze

      # @return [Partials]
      def self.instance
        @instance ||= new
      end

      # @param filename [String]
      # @return [Boolean]
      def self.partial?(filename)
        File.basename(filename).start_with?('_')
      end

      # @param source [Solargraph::Source] a transformed view
      # @param render [Solargraph::Pin::Method] the method the view runs in
      # @return [Array<Solargraph::Pin::Parameter>]
      def parameters(source, render)
        return [] unless self.class.partial?(source.filename)

        (strict_locals(source) || []).each { |param| param.closure = render }
      end

      private

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
    end
  end
end
