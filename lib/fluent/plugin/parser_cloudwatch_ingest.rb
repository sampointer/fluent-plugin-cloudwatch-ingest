require 'fluent/plugin/parser_regexp'
require 'fluent/time'

module Fluent
  module Plugin
    class CloudwatchIngestParser < RegexpParser
      Plugin.register_parser('cloudwatch_ingest', self)

      config_set_default :expression, '^(?<message>.+)$'
      config_set_default :time_format, '%Y-%m-%d %H:%M:%S.%L'
      config_set_default :event_time, true

      def parse(event)
        time = nil
        record = nil
        super(event.message) do |t, r|
          time = t
          record = r
        end

        # We do String processing on the event time here to
        # avoid rounding errors introduced by floating point
        # arithmetic.
        event_s  = event.timestamp.to_s[0..9]
        event_ns = event.timestamp.to_s[10..-1].to_i * 1_000_000

        time = Fluent::EventTime.new(event_s, event_ns) if @event_time

        yield time, record
      end
    end
  end
end
