# Changelog

## 0.1.3

* Initial release

## 0.2.1

* AWS SDK logging
* Code reorganization

## 0.3.1

* Limit events per API call
* Parser constructor fix (@snltd)

## 0.4.0

* Optionally fetch oldest logs first (@chaeyk)

## 0.5.4

* Optionally parse the body as JSON into structured fields

## 0.6.0

* Add statsd telemetry

## 1.0.0

* Print a stack trace when recusing exceptions (@chaeyk)
* If stored API token is invalid or corrupt, use a stored timestamp (@chaeyk)
* Truncate statefile before saving (@chaeyk)
* Amend how `api_interval` is used (see README.md) (@chaeyk)
* Improve null stream detection (@chaeyk)
* Remove streams from state file that are no longer present (@chaeyk)
* Apply `error_interval` when failing to get statefile lock (@chaeyk)
* `api_interval` deprecated in favour of `error_interval`

## 1.1.0

* Update aws-sdk runtime dependency

## 1.2.0

* Add the ability to inject both the `ingestion_time returned from the the Cloudwatch Logs API, and the time that this plugin ingested the event into the record.
* Add telemetry to the parser

Both of these changes are designed to make debugging ingestion problems from high-volume log groups easier.

## 1.3.0

* Add `log_group_exclude_regexp` to allow optional exclusion of log groups by regexp

## 1.4.0

* Refuse to emit records with a blank (or newline only) message
* Emit metric `events.emitted.blocked` to expose these alongside logging
* Add plugin skew time to telemetry optionally emitted from the parser

## 1.5.0

* Limit the number of streams to be processed with each log stream describe call
* new parameter `max_log_streams_per_group` with a default of 50 (the default value for *limit* on API calls). This can be increased or decreased to limit the throttling of calls to AWS API
* Bail out of processing if fluentd has been stopped
* Move to the modular v3 of the aws-sdk
