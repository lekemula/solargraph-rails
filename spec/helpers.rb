module Helpers
  def load_string(filename, str)
    source = Solargraph::Source.load_string(str, filename)
    api_map.map(source) # api_map should be defined in the spec
    source
  end

  def load_sources(*sources)
    workspace = Solargraph::Workspace.new('*')
    sources.each { |s| workspace.merge(s) }
    library = Solargraph::Library.new(workspace)
    library.map!
    api_map.catalog library # api_map should be defined in the spec
  end

  def assert_matches_definitions(map, class_name, definition_name, update: false)
    definitions_file = "spec/definitions/#{definition_name}.yml"
    definitions = YAML.load_file(definitions_file)

    class_methods =
      map.get_methods(
        class_name,
        scope: :class,
        visibility: %i[public protected private]
      )

    instance_methods =
      map.get_methods(
        class_name,
        scope: :instance,
        visibility: %i[public protected private]
      )

    skipped = 0
    typed = 0
    errors = []

    definitions.each do |meth, data|
      unless meth.start_with?('.') || meth.start_with?('#')
        meth = meth.gsub(class_name, '')
      end

      pin =
        if meth.start_with?('.')
          class_methods.find { |p| p.name == meth[1..-1] }
        elsif meth.start_with?('#')
          instance_methods.find { |p| p.name == meth[1..-1] }
        end

      typed += 1 if data['types'] != ['undefined']
      skipped += 1 if data['skip']

      # Completion is found, but marked as skipped
      if pin && data['skip']
        puts <<~STR
          #{class_name}#{meth} is marked as skipped in #{definitions_file}, but is actually present.
          Consider setting skip=false
        STR
      elsif pin
        assert_entry_valid(pin, data, update: update)
        data['skip'] = false if update
      elsif update
        skipped += 1
        data['skip'] = true
      elsif data['skip']
        next
      else
        errors << meth
      end
    end

    if errors.any?
      raise <<~STR
        The following methods could not be found despite being listed in #{definition_name}.yml:
        #{errors}
      STR
    end

    if update
      File.write("spec/definitions/#{definition_name}.yml", definitions.to_yaml)
    end

    total = definitions.keys.size

    if ENV['PRINT_STATS'] != nil
      puts(
        {
          class_name: class_name,
          total: total,
          covered: total - skipped,
          typed: typed,
          percent_covered: percent(total - skipped, total),
          percent_typed: percent(typed, total)
        }
      )
    end
  end

  def percent(a, b)
    ((a.to_f / b) * 100).round(1)
  end

  def assert_entry_valid(pin, data, update: false)
    effective_type = pin.return_type.map(&:tag)
    specified_type = data['types']

    if effective_type != specified_type
      if update
        data['types'] = effective_type
      else
        raise "#{pin.path} return type is wrong. Expected #{specified_type}, got: #{effective_type}"
      end
    end
  end

  class Injector
    attr_reader :files
    def initialize(folder)
      @folder = folder
      @files = []
    end

    def write_file(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      @files << path
    end
  end

  def use_workspace(folder, &block)
    injector = Injector.new(folder)
    map = nil

    Dir.chdir folder do
      yield injector if block_given?
      map = Solargraph::ApiMap.load('./')
      injector.files.each { |f| File.delete(f) }
    end

    map
  end

  def assert_public_instance_method(map, query, return_type, &block)
    pin = find_pin(query, map)
    expect(pin).to_not be_nil
    expect(pin.scope).to eq(:instance)
    expect(pin.return_type.map(&:tag)).to eq(return_type)

    yield pin if block_given?
  end

  def assert_class_method(map, query, return_type, &block)
    pin = find_pin(query, map)
    expect(pin).to_not be_nil
    expect(pin.scope).to eq(:class)
    expect(pin.return_type.map(&:tag)).to eq(return_type)

    yield pin if block_given?
  end

  def assert_namespace(map, query, &block)
    pin = find_pin(query, map)
    expect(pin).to_not be_nil
    expect(pin.scope).to eq(:class)
    expect(pin.return_type.map(&:tag)).to eq(["Class<#{query}>"])

    yield pin if block_given?
  end

  def find_pin(path, map = api_map)
    find_pins(path, map).first
  end

  def find_pins(path, map = api_map)
    map.pins.select { |p| p.path == path }
  end

  def local_pins(map = api_map)
    map.pins.select { |p| p.filename }
  end

  def completion_at(filename, position, map = api_map)
    clip = map.clip_at(filename, position)
    cursor = clip.send(:cursor)
    word = cursor.chain.links.first.word

    Solargraph.logger.debug(
      "Complete: word=#{word}, links=#{cursor.chain.links}"
    )

    clip.complete.pins.map(&:name)
  end

  def completions_for(map, filename, position)
    clip = map.clip_at(filename, position)

    clip.complete.pins.map { |pin| [pin.name, pin.return_type.map(&:tag)] }.to_h
  end
end
