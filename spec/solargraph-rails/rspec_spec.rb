require 'spec_helper'

RSpec.describe Solargraph::Rails::Rspec do
  let(:api_map) { Solargraph::ApiMap.new }

  it 'generates method for described_class' do
    load_string 'spec/models/some_namespace/transaction_spec.rb', <<-RUBY
RSpec.describe SomeNamespace::Transaction, type: :model do
  it 'should do something' do
    descr
  end
end 
    RUBY

    assert_public_instance_method(api_map, '#described_class', ['Class<SomeNamespace::Transaction>']) do |pin|
      expect(pin.location.filename).to eq(
        File.expand_path('spec/models/some_namespace/transaction_spec.rb')
      )
      expect(pin.location.range.to_hash).to eq(
        { start: { line: 0, character: 0 }, end: { line: 0, character: 15 } }
      )
    end

    expect(completion_at('spec/models/some_namespace/transaction_spec.rb', [2, 9])).to include("described_class")
  end

  it 'generates method for lets/subject definitions' do
    load_string 'spec/models/some_namespace/transaction_spec.rb', <<-RUBY
RSpec.describe SomeNamespace::Transaction, type: :model do
  subject(:transaction) { described_class.new }
  let(:something) { 1 }

  it 'should do something' do
    tran
    some
  end
end 
    RUBY
    
    assert_public_instance_method(api_map, '#transaction', ["undefined"])
    assert_public_instance_method(api_map, '#something', ["undefined"])
    expect(completion_at('spec/models/some_namespace/transaction_spec.rb', [5, 8])).to include("transaction")
    expect(completion_at('spec/models/some_namespace/transaction_spec.rb', [6, 8])).to include("something")
  end
end
