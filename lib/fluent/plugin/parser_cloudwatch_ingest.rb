require 'fluent/plugin/parser_regexp'
require 'fluent/time'
require 'multi_json'

module Fluent
  module Plugin
    class CloudwatchIngestParser < RegexpParser
      Plugin.register_parser('cloudwatch_ingest', self)

      config_param :expression, :string, default: '^(?<message>.+)$'
      config_param :time_format, :string, default: '%Y-%m-%d %H:%M:%S.%L'
      config_param :event_time, :bool, default: true
      config_param :inject_group_name, :bool, default: true
      config_param :inject_stream_name, :bool, default: true
      config_param :parse_json_body, :bool, default: false
      config_param :fail_on_unparsable_json, :bool, default: false

      def initialize
        super
      end

      def configure(conf)
        super
      end

      def parse(event, group, stream)
        time = nil
        record = nil
        super(event.message) do |t, r|
          time = t
          record = r
        end

        # Optionally attempt to parse the body as json
        if @parse_json_body
          begin
            json_body = MultiJson.load(record)
            json_body.each_pair do |k,v|
              record[k.to_s] = v.to_s
            end
          rescue MultiJson::ParseError
            if @fail_on_unparsable_json
              yield nil, nil
              return
            end
          end
        end

        # Inject optional fields
        record['log_group_name'] = group if @inject_group_name
        record['log_stream_name'] = stream if @inject_stream_name

        # We do String processing on the event time here to
        # avoid rounding errors introduced by floating point
        # arithmetic.
        event_s  = event.timestamp.to_s[0..9].to_i
        event_ns = event.timestamp.to_s[10..-1].to_i * 1_000_000

        time = Fluent::EventTime.new(event_s, event_ns) if @event_time

        yield time, record
      end
    end
  end
end
