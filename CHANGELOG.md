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
