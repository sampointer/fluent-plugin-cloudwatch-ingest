# Fluent::Plugin::Cloudwatch::Ingest [![Circle CI](https://circleci.com/gh/sampointer/fluent-plugin-cloudwatch-ingest.svg?style=svg)](https://circleci.com/gh/sampointer/fluent-plugin-cloudwatch-ingest)

**This gem is not yet ready for production release or use.**

## Introduction

This gem was created out of frustration with existing solutions for Cloudwatch log ingestion into a Fluentd pipeline. Specifically, it has been designed to support:

* The 0.14.x fluentd plugin API
* Native IAM including cross-account authentication via STS
* Tidy state serialization
* HA configurations without ingestion duplication

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'fluent-plugin-cloudwatch-ingest'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install fluent-plugin-cloudwatch-ingest

## Usage
```
<source>
  @type cloudwatch
  region us-east-1
  sts_enabled true
  sts_arn arn:aws:iam::123456789012:role/role_in_another_account
  sts_session_name fluentd-dev
  log_group_name_prefix /aws/lambda
  log_stream_name_prefix 2017
  state_file_name /mnt/nfs/cloudwatch.state
  lock_state_file true
  interval 120
  api_interval 300  # Time to wait between API call failures before retry
</source>
```

### Authentication
The plugin will assume an IAM instance role. Without either of the `sts_*` options that role will be used for authentication. With those set the plugin will
attempt to `sts:AssumeRole` the `sts_arn`. This is useful for fetching logs from many accounts where the fluentd infrastructure lives in one single account.

### Prefixes
Both the `log_group_name_prefix` and `log_stream_name_prefix` may be omitted, in which case all groups and streams will be ingested. For performance reasons it is often desirable to set the `log_stream_name_prefix` to be today's date, managed by a configuration management system.

### State file
The state file is a YAML serialization of the current ingestion state. When running in a HA configuration this should be placed on a shared filesystem, such as EFS.
The state file is opened with an exclusive write call and as such also functions as a lock file in HA configurations. See below.

### HA Setup
When the state file is location on a shared filesystem an exclusive write lock will attempted each `interval`.
As such it is safe to run multiple instances of this plugin consuming from the same CloudWatch logging source without fear of duplication, as long as they share a state file.
In a properly configured auto-scaling group this provides for uninterrupted log ingestion in the event of a failure of any single node.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/fluent-plugin-cloudwatch-ingest.

