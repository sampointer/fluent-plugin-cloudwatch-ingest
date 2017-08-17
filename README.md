# Fluentd Cloudwatch Plugin
[![Circle CI](https://circleci.com/gh/sampointer/fluent-plugin-cloudwatch-ingest.svg?style=shield)](https://circleci.com/gh/sampointer/fluent-plugin-cloudwatch-ingest) [![Gem Version](https://badge.fury.io/rb/fluent-plugin-cloudwatch-ingest.svg)](https://badge.fury.io/rb/fluent-plugin-cloudwatch-ingest) ![](http://ruby-gem-downloads-badge.herokuapp.com/fluent-plugin-cloudwatch-ingest?type=total) [![Join the chat at https://gitter.im/fluent-plugin-cloudwatch-ingest](https://badges.gitter.im/fluent-plugin-cloudwatch-ingest.svg)](https://gitter.im/fluent-plugin-cloudwatch-ingest/Lobby?utm_source=share-link&utm_medium=link&utm_campaign=share-link) [![Dependency Status](https://gemnasium.com/badges/github.com/sampointer/fluent-plugin-cloudwatch-ingest.svg)](https://gemnasium.com/github.com/sampointer/fluent-plugin-cloudwatch-ingest)

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
  @type cloudwatch_ingest
  region us-east-1
  sts_enabled true
  sts_arn arn:aws:iam::123456789012:role/role_in_another_account
  sts_session_name fluentd-dev
  aws_logging_enabled true
  log_group_name_prefix /aws/lambda
  log_stream_name_prefix 2017
  state_file_name /mnt/nfs/cloudwatch.state
  interval 60
  error_interval 5          # Time to wait between error conditions before retry
  limit_events 10000        # Number of events to fetch in any given iteration
  event_start_time 0        # Do not fetch events before this time (UNIX epoch, miliseconds)
  oldest_logs_first false   # When true fetch the oldest logs first
  telemetry false           # Produce statsd telemetry
  statsd_endpoint localhost # Endpoint to which telemetry should be sent
  <parse>
    @type cloudwatch_ingest
    expression /^(?<message>.+)$/
    time_format %Y-%m-%d %H:%M:%S.%L
    event_time true                        # take time from the Cloudwatch event, rather than parse it from the body
    inject_group_name true                 # inject the group name into the record
    inject_stream_name true                # inject the stream name into the record
    inject_cloudwatch_ingestion_time false # inject the `ingestion_time` as returned by the Cloudwatch API
    inject_plugin_ingestion_time false     # inject the 13 digit epoch time at which the plugin ingested the event
    parse_json_body false                  # Attempt to parse the body as json and add structured fields from the result
    fail_on_unparsable_json false          # If the body cannot be parsed as json do not ingest the record
  </parse>
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
When the state file is located on a shared filesystem an exclusive write lock will attempted each `interval`.
As such it is safe to run multiple instances of this plugin consuming from the same CloudWatch logging source without fear of duplication, as long as they share a state file.
In a properly configured auto-scaling group this provides for uninterrupted log ingestion in the event of a failure of any single node.

### JSON parsing
With the `parse_json_body` option set to `true` the plugin will attempt to parse the body of the log entry as JSON. If this is successful any field/value pairs found will be added to the emitted record as structured fields.

If `fail_on_unparsable_json` is set to `true` a record body consisting of malformed json will cause the record to be rejected. You may wish to leave this setting as false if the plugin is ingesting multiple log groups with a mixture of json/structured and unstructured content.

The `expression` is applied before JSON parsing is attempted. One may therefore extract a JSON fragment from within the event body if it is decorated with additional free-form text.

### Telemetry
With `telemetry` set to `true` and a valid `statsd_endpoint` the plugin will emit telemetry in statsd format to 8125:UDP. It is up to you to configure your statsd-speaking daemon to add any prefix or tagging that you might want.

The metrics emitted in this version are:

```
api.calls.describeloggroups.attempted
api.calls.describeloggroups.failed
api.calls.describelogstreams.attempted
api.calls.describelogstreams.failed
api.calls.getlogevents.attempted
api.calls.getlogevents.failed
api.calls.getlogevents.invalid_token
events.emitted.success
```

### Sub-second timestamps
When using `event_time true` the `@timestamp` field for the record is taken from the time recorded against the event by Cloudwatch. This is the most common mode to run in as it's an easy path to normalization: all of your Lambdas or other AWS service need not have the same, valid, `time_format` nor a regex that matches every case.

If your output plugin supports sub-second precision (and you're running fluentd 0.14.x) you'll "enjoy" sub-second precision.

#### Elasticsearch
It is a common pattern to use fluentd alongside the [fluentd-plugin-elasticsearch](https://github.com/uken/fluent-plugin-elasticsearch) plugin, either directly or via [fluent-plugin-aws-elasticsearch-service](https://github.com/atomita/fluent-plugin-aws-elasticsearch-service), to ingest logs into Elasticsearch.

Prior to version 1.9.5 there was a bug within that plugin which, via an unwise cast, caused records without a named timestamp field to be cast to `DateTime`, losing the precision. This PR: https://github.com/uken/fluent-plugin-elasticsearch/pull/249 fixed that issue.

### IAM
IAM is a tricky and often bespoke subject. Here's a starter that will ingest all of the logs for all of your Lambdas in the account in which the plugin is running:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "logs:DescribeLogGroups",
                "logs:DescribeLogStreams",
                "logs:DescribeMetricFilters",
                "logs:FilterLogEvents",
                "logs:GetLogEvents"
            ],
            "Resource": [
                "arn:aws:logs:eu-west-1:123456789012:log-group:/aws/lambda/*:*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "logs:DescribeLogGroups",
            ],
            "Resource": [
                "arn:aws:logs:eu-west-1:123456789012:log-group:*:*"
            ]
        }
    ]
}
```

### Cross-account authentication
Broadly speaking the IAM instance role of the host on which the plugin is running needs to be able to `sts:AssumeRole` the `sts_arn` (and obviously needs `sts_enabled` to be true).

The assumed role should look more-or-less like that above in terms of the actions and resource combinations required.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/sampointer/fluent-plugin-cloudwatch-ingest.

