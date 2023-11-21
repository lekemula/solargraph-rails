require 'spec_helper'

RSpec.describe Solargraph::Rails::Rspec do
  let(:api_map) { Solargraph::ApiMap.new }
  let(:library) { Solargraph::Library.new }

  it 'generates method for described_class' do
    filename = File.expand_path('spec/models/some_namespace/transaction_spec.rb')
    load_string filename, <<-RUBY
RSpec.describe SomeNamespace::Transaction, type: :model do
  it 'should do something' do
    described_c
  end
end 
    RUBY

    assert_public_instance_method(api_map, 'RSpec::ExampleGroups::SomeNamespaceTransaction#described_class', ['Class<SomeNamespace::Transaction>']) do |pin|
      expect(pin.location.filename).to eq(filename)
      expect(pin.location.range.to_hash).to eq(
        { start: { line: 0, character: 0 }, end: { line: 0, character: 15 } }
      )
    end

    expect(completion_at(filename, [2, 15])).to include("described_class")
  end

  it 'generates method for lets/subject definitions' do
    filename = File.expand_path('spec/models/some_namespace/transaction_spec.rb')
    load_string filename, <<-RUBY
RSpec.describe SomeNamespace::Transaction, type: :model do
  subject(:transaction) { described_class.new }
  let(:something) { 1 }

  it 'should do something' do
    tran
    some
  end
end 
    RUBY
    
    assert_public_instance_method(api_map, 'RSpec::ExampleGroups::SomeNamespaceTransaction#transaction', ["undefined"])
    assert_public_instance_method(api_map, 'RSpec::ExampleGroups::SomeNamespaceTransaction#something', ["undefined"])
    expect(completion_at(filename, [5, 8])).to include("transaction")
    expect(completion_at(filename, [6, 8])).to include("something")
  end

  it 'generates modules for describe/context blocks' do
    filename = File.expand_path('spec/models/some_namespace/transaction_spec.rb')
    load_string filename, <<-RUBY
RSpec.describe SomeNamespace::Transaction, type: :model do
  describe 'describing something' do
    context 'when some context' do
      let(:something) { 1 }

      it 'should do something' do
      end
    end

    context 'when some other context' do
      let(:something) { 1 }

      it 'should do something' do
      end
    end
  end
end 
    RUBY

    assert_namespace(api_map, 'RSpec::ExampleGroups::SomeNamespaceTransaction')
    assert_namespace(api_map, 'RSpec::ExampleGroups::SomeNamespaceTransaction::DescribingSomething')
    assert_namespace(api_map, 'RSpec::ExampleGroups::SomeNamespaceTransaction::DescribingSomething::WhenSomeContext')
    assert_namespace(api_map, 'RSpec::ExampleGroups::SomeNamespaceTransaction::DescribingSomething::WhenSomeOtherContext')
  end

  it 'shouldn\'t complete for rspec definitions from other spec files' do
    filename1 = File.expand_path('spec/models/test_one_spec.rb')
    file1 = load_string filename1, <<-RUBY
RSpec.describe TestOne, type: :model do
  let(:variable_one) { 1 }

  it 'should do something' do
    vari
  end
end
    RUBY

    filename2 = File.expand_path('spec/models/test_two_spec.rb')
    file2 = load_string filename2, <<-RUBY
RSpec.describe TestTwo, type: :model do
    it 'should do something' do
      vari
    end
    context 'test', sometag: true do
    end
end
    RUBY

    load_sources(file1, file2)

    expect(completion_at(filename1, [4, 10])).to include("variable_one")
    expect(completion_at(filename2, [2, 10])).to_not include("variable_one")
  end
end
