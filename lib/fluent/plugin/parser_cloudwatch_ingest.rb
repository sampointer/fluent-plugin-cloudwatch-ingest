require 'fluent/plugin/parser_regexp'
require 'fluent/time'

module Fluent
  module Plugin
    class CloudwatchIngestParser < RegexpParser
      Plugin.register_parser("cloudwatch_ingest", self)

      config_set_default :expression, %q{/(?<message>.+)}
      config_set_default :time_format, '%Y-%m-%d %H:%M:%S.%L'

      def parse(event)
        time, record = super(event.message) { |t,r| t, r }

        # We do String processing on the event time here to
        # avoid rounding errors introduced by floating point
        # arithmetic.
        event_s  = event.timestamp.to_s[0..9]
        event_ns = event.timestamp.to_s[10..-1].to_i * 1000000


        # If we cannot parse the time from the message itself (either because
        # a time field is not included in the format, or it is not matched)
        # then we take the time from the cloudwatch event time
        time = time ? time : Fluent::EventTime.new(event_s, event_ms)
        yield time, record
      end
    end
  end
end
