require 'date'
require 'fluent/plugin/parser_regexp'
require 'fluent/time'
require 'multi_json'
require 'statsd-ruby'

module Fluent
  module Plugin
    class CloudwatchIngestParser < RegexpParser
      Plugin.register_parser('cloudwatch_ingest', self)

      config_param :expression, :string, default: '^(?<message>.+)$'
      config_param :time_format, :string, default: '%Y-%m-%d %H:%M:%S.%L'
      config_param :event_time, :bool, default: true
      config_param :inject_group_name, :bool, default: true
      config_param :inject_cloudwatch_ingestion_time, :string, default: false
      config_param :inject_plugin_ingestion_time, :string, default: false
      config_param :inject_stream_name, :bool, default: true
      config_param :parse_json_body, :bool, default: false
      config_param :fail_on_unparsable_json, :bool, default: false
      config_param :telemetry, :bool, default: false
      config_param :statsd_endpoint, :string, default: 'localhost'

      def initialize
        super
      end

      def configure(conf)
        super
        @statsd = Statsd.new @statsd_endpoint, 8125 if @telemetry
      end

      def metric(method, name, value = 0)
        case method
        when :increment
          @statsd.send(method, name) if @telemetry
        else
          @statsd.send(method, name, value) if @telemetry
        end
      end

      def parse(event, group, stream)
        metric(:increment, 'parser.record.attempted')

        time = nil
        record = nil
        super(event.message) do |t, r|
          time = t
          record = r
        end

        # Optionally attempt to parse the body as json
        if @parse_json_body
          begin
            # Whilst we could just merge! the parsed
            # message into the record we'd bork on
            # nested keys. Force level one Strings.
            json_body = MultiJson.load(record['message'])
            metric(:increment, 'parser.json.success')
            json_body.each_pair do |k, v|
              record[k.to_s] = v.to_s
            end
          rescue MultiJson::ParseError
            metric(:increment, 'parser.json.failed')
            if @fail_on_unparsable_json
              yield nil, nil
              return
            end
          end
        end

        # Inject optional fields
        record['log_group_name'] = group if @inject_group_name
        record['log_stream_name'] = stream if @inject_stream_name

        if @inject_plugin_ingestion_time
          now = DateTime.now
          record[@inject_plugin_ingestion_time] = now.iso8601
        end

        if @inject_cloudwatch_ingestion_time
          epoch_ms = event.ingestion_time.to_f / 1000
          time = Time.at(epoch_ms)
          record[@inject_cloudwatch_ingestion_time] =
            time.to_datetime.iso8601(3)
        end

        # Optionally emit cloudwatch event and ingestion time skew telemetry
        if @telemetry
          metric(
            :gauge,
            'parser.ingestion_skew',
            event.ingestion_time - event.timestamp
          )
        end

        # Optionally emit @timestamp and plugin ingestion time skew
        if @telemetry
          metric(
            :gauge,
            'parser.plugin_skew',
            now.strftime('%Q').to_i - event.timestamp
          )
        end

        # We do String processing on the event time here to
        # avoid rounding errors introduced by floating point
        # arithmetic.
        event_s  = event.timestamp.to_s[0..9].to_i
        event_ns = event.timestamp.to_s[10..-1].to_i * 1_000_000

        time = Fluent::EventTime.new(event_s, event_ns) if @event_time

        metric(:increment, 'parser.record.success')
        yield time, record
      end
    end
  end
end
