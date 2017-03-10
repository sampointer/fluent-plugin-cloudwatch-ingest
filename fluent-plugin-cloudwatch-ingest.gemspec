# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'fluent/plugin/cloudwatch/ingest/version'

Gem::Specification.new do |spec|
  spec.name          = "fluent-plugin-cloudwatch-ingest"
  spec.version       = Fluent::Plugin::Cloudwatch::Ingest::VERSION
  spec.authors       = ["Sam Pointer"]
  spec.email         = ["san@outsidethe.net"]

  spec.summary       = %q{Fluentd plugin to ingest cloudwatch logs}
  spec.description   = %q{Alternative to ryotarai/fluent-plugin-cloudwatch-logs}
  spec.homepage      = "https://github.com/sampointer/fluent-plugin-cloudwatch-ingest"

  # Prevent pushing this gem to RubyGems.org by setting 'allowed_push_host', or
  # delete this section to allow pushing this gem to any host.
  if spec.respond_to?(:metadata)
    spec.metadata['allowed_push_host'] = "TODO: Set to 'http://mygemserver.com'"
  else
    raise "RubyGems 2.0 or newer is required to protect against public gem pushes."
  end

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.10"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "rspec"
  spec.add_development_dependency "rubocop"

  spec.add_dependency "fluentd", "~>0.14.13"
end
