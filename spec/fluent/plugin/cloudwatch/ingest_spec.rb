require 'spec_helper'

describe Fluent::Plugin::Cloudwatch::Ingest do
  it 'has a version number' do
    expect(Fluent::Plugin::Cloudwatch::Ingest::VERSION).not_to be nil
  end

  it 'does something useful' do
    expect(false).to eq(false)
  end
end
