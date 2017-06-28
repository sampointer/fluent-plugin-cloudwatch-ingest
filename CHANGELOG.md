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
* Apply `api_interval` when failing to get statefile lock (@chaeyk)
