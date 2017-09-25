lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'fluent/plugin/cloudwatch/ingest/version'

Gem::Specification.new do |spec|
  spec.name          = 'fluent-plugin-cloudwatch-ingest'
  spec.version       = Fluent::Plugin::Cloudwatch::Ingest::VERSION
  spec.authors       = ['Sam Pointer']
  spec.email         = ['san@outsidethe.net']

  spec.summary       = 'Fluentd plugin to ingest AWS Cloudwatch logs'
  spec.description   = 'Fluentd plugin to ingest AWS Cloudwatch logs'
  spec.homepage      = 'https://github.com/sampointer/fluent-plugin-cloudwatch-ingest'

  # Prevent pushing this gem to RubyGems.org by setting 'allowed_push_host', or
  # delete this section to allow pushing this gem to any host.
  if spec.respond_to?(:metadata) # rubocop:disable all
    spec.metadata['allowed_push_host'] = 'https://rubygems.org'
  else
    raise 'RubyGems 2.0 or newer is required to protect against public gem pushes.' # rubocop:disable all
  end

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) } # rubocop:disable all
  spec.bindir        = 'exe'
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  spec.add_development_dependency 'bundler', '~> 1.10'
  spec.add_development_dependency 'rake', '~> 12.1'
  spec.add_development_dependency 'rspec'
  spec.add_development_dependency 'rubocop'

  spec.add_dependency 'fluentd', '~>0.14.20'
  spec.add_dependency 'aws-sdk-core', '~>3.6.0'
  spec.add_dependency 'aws-sdk-cloudwatch', '~>1.2.0'
  spec.add_dependency 'multi_json', '~>1.12'
  spec.add_dependency 'statsd-ruby', '~>1.4.0'
end
