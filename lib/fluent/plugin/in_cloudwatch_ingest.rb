require 'aws-sdk'
require 'fluent/config/error'
require 'fluent/plugin/input'
require 'fluent/plugin/parser'
require 'json'
require 'pathname'
require 'psych'
require 'statsd-ruby'

module Fluent::Plugin
  class CloudwatchIngestInput < Fluent::Plugin::Input
    Fluent::Plugin.register_input('cloudwatch_ingest', self)
    helpers :compat_parameters, :parser

    desc 'The region of the source cloudwatch logs'
    config_param :region, :string, default: 'us-east-1'
    desc 'Enable STS for cross-account IAM'
    config_param :sts_enabled, :bool, default: false
    desc 'The IAM role ARN in the source account to use when STS is enabled'
    config_param :sts_arn, :string, default: ''
    desc 'The session name for use with STS'
    config_param :sts_session_name, :string, default: 'fluentd'
    desc 'Log group name or prefix. Not setting means "all"'
    config_param :log_group_name_prefix, :string, default: ''
    desc 'Log stream name or prefix. Not setting means "all"'
    config_param :log_stream_name_prefix, :string, default: ''
    desc 'Log group regexp to exclude, despite matching'
    config_param :log_group_exclude_regexp, :string, default: ''
    desc 'State file name'
    config_param :state_file_name, :string, default: '/var/spool/td-agent/cloudwatch.state' # rubocop:disable LineLength
    desc 'Fetch logs every interval'
    config_param :interval, :time, default: 60
    desc 'Time to pause between error conditions'
    config_param :error_interval, :time, default: 5
    config_param :api_interval, :time
    desc 'Tag to apply to record'
    config_param :tag, :string, default: 'cloudwatch'
    desc 'Enabled AWS SDK logging'
    config_param :aws_logging_enabled, :bool, default: false
    desc 'Limit the number of events fetched in any iteration'
    config_param :limit_events, :integer, default: 10_000
    desc 'Do not fetch events before this time'
    config_param :event_start_time, :integer, default: 0
    desc 'Fetch the oldest logs first'
    config_param :oldest_logs_first, :bool, default: false
    desc 'Turn on telemetry'
    config_param :telemetry, :bool, default: false
    desc 'Statsd endpoint to which telemetry should be written'
    config_param :statsd_endpoint, :string, default: 'localhost'
    config_section :parse do
      config_set_default :@type, 'cloudwatch_ingest'
      desc 'Regular expression with which to parse the event message'
      config_param :expression, :string, default: '^(?<message>.+)$'
      desc 'Take the timestamp from the event rather than the expression'
      config_param :event_time, :bool, default: true
      desc 'Time format to use when parsing event message'
      config_param :time_format, :string, default: '%Y-%m-%d %H:%M:%S.%L'
      desc 'Inject the log group name into the record'
      config_param :inject_group_name, :bool, default: true
      desc 'Inject the log stream name into the record'
      config_param :inject_stream_name, :bool, default: true
    end

    def initialize
      super
      log.info('Starting fluentd-plugin-cloudwatch-ingest')
    end

    def metric(method, name, value = 0)
      case method
      when :increment
        @statsd.send(method, name) if @telemetry
      else
        @statsd.send(method, name, value) if @telemetry
      end
    end

    def configure(conf)
      super
      compat_parameters_convert(conf, :parser)
      parser_config = conf.elements('parse').first
      unless parser_config
        raise Fluent::ConfigError, '<parse> section is required.'
      end
      unless parser_config['expression']
        raise Fluent::ConfigError, 'parse/expression is required.'
      end
      unless parser_config['event_time']
        raise Fluent::ConfigError, 'parse/event_time is required.'
      end

      # Configure telemetry, if enabled
      @statsd = Statsd.new @statsd_endpoint, 8125 if @telemetry

      # Fixup deprecated options
      if @api_interval
        @error_interval = @api_interval
        log.warn('api_interval is deprecated for error_interval')
      end

      @parser = parser_create(conf: parser_config)
      log.info('Configured fluentd-plugin-cloudwatch-ingest')
    end

    def start
      super
      log.info('Started fluentd-plugin-cloudwatch-ingest')

      # Get a handle to Cloudwatch
      aws_options = {}
      Aws.config[:region] = @region
      Aws.config[:logger] = log if @aws_logging
      log.info("Working in region #{@region}")

      if @sts_enabled
        aws_options[:credentials] = Aws::AssumeRoleCredentials.new(
          role_arn: @sts_arn,
          role_session_name: @sts_session_name
        )

        log.info("Using STS for authentication with source account ARN: #{@sts_arn}, session name: #{@sts_session_name}") # rubocop:disable LineLength
      else
        log.info('Using local instance IAM role for authentication')
      end
      @aws = Aws::CloudWatchLogs::Client.new(aws_options)
      @finished = false
      @thread = Thread.new(&method(:run))
    end

    def shutdown
      @finished = true
      @thread.join
    end

    private

    def emit(event, log_group_name, log_stream_name)
      @parser.parse(event, log_group_name, log_stream_name) do |time, record|
        router.emit(@tag, time, record)
        metric(:increment, 'events.emitted.success')
      end
    end

    def log_groups(log_group_prefix)
      log_groups = []

      # Fetch all log group names
      next_token = nil
      loop do
        begin
          metric(:increment, 'api.calls.describeloggroups.attempted')
          response = if !log_group_prefix.empty?
                       @aws.describe_log_groups(
                         log_group_name_prefix: log_group_prefix,
                         next_token: next_token
                       )
                     else
                       @aws.describe_log_groups(
                         next_token: next_token
                       )
                     end

          regex = Regexp.new(@log_group_exclude_regexp)
          response.log_groups.each do |group|
            if !@log_group_exclude_regexp.empty?
              if regex.match(group.log_group_name)
                log.info("Excluding log_group #{group.log_group_name} due to log_group_exclude_regexp #{@log_group_exclude_regexp}") # rubocop:disable LineLength
                metric(:increment, 'api.calls.describeloggroups.excluded')
              else
                log_groups << group.log_group_name
              end
            else
              log_groups << group.log_group_name
            end
          end
          break unless response.next_token
          next_token = response.next_token
        rescue => boom
          log.error("Unable to retrieve log groups: #{boom.inspect}")
          metric(:increment, 'api.calls.describeloggroups.failed')
          next_token = nil
          sleep @error_interval
          retry
        end
      end
      log.info("Found #{log_groups.size} log groups")

      return log_groups
    end

    def log_streams(log_group_name, log_stream_name_prefix)
      log_streams = []
      next_token = nil
      loop do
        begin
          metric(:increment, 'api.calls.describelogstreams.attempted')
          response = if !log_stream_name_prefix.empty?
                       @aws.describe_log_streams(
                         log_group_name: log_group_name,
                         log_stream_name_prefix: log_stream_name_prefix,
                         next_token: next_token
                       )
                     else
                       @aws.describe_log_streams(
                         log_group_name: log_group_name,
                         next_token: next_token
                       )
                     end

          response.log_streams.each { |s| log_streams << s.log_stream_name }
          break unless response.next_token
          next_token = response.next_token
        rescue => boom
          log.error("Unable to retrieve log streams for group #{log_group_name} with stream prefix #{log_stream_name_prefix}: #{boom.inspect}") # rubocop:disable LineLength
          metric(:increment, 'api.calls.describelogstreams.failed')
          log_streams = []
          next_token = nil
          sleep @error_interval
          retry
        end
      end
      log.info("Found #{log_streams.size} streams for #{log_group_name}")

      return log_streams
    end

    def process_stream(group, stream, next_token, start_time, state)
      event_count = 0

      metric(:increment, 'api.calls.getlogevents.attempted')
      response = @aws.get_log_events(
        log_group_name: group,
        log_stream_name: stream,
        next_token: next_token,
        limit: @limit_events,
        start_time: start_time,
        start_from_head: @oldest_logs_first
      )

      response.events.each do |e|
        begin
          emit(e, group, stream)
          event_count += 1
        rescue => boom
          log.error("Failed to emit event #{e}: #{boom.inspect}")
        end
      end

      has_stream_timestamp = true if state.store[group][stream]['timestamp']

      if !has_stream_timestamp && response.events.count.zero?
        # This stream has returned no data ever.
        # In this case, don't save state (token could be an invalid one)
      else
        # Once all events for this stream have been processed,
        # in this iteration, store the forward token
        state.new_store[group][stream]['token'] = response.next_forward_token
        if response.events.last
          state.new_store[group][stream]['timestamp'] =
            response.events.last.timestamp
        else
          state.new_store[group][stream]['timestamp'] =
            state.store[group][stream]['timestamp']
        end
      end

      return event_count
    end

    def run
      until @finished
        begin
          state = State.new(@state_file_name, log)
        rescue => boom
          log.info("Failed lock state. Sleeping for #{@error_interval}: "\
                   "#{boom.inspect}")
          sleep @error_interval
          next
        end

        event_count = 0

        # Fetch the streams for each log group
        log_groups(@log_group_name_prefix).each do |group|
          # For each log stream get and emit the events
          log_streams(group, @log_stream_name_prefix).each do |stream|
            state.store[group][stream] = {} unless state.store[group][stream]

            log.info("processing stream: #{stream}")

            # See if we have some stored state for this group and stream.
            # If we have then use the stored forward_token to pick up
            # from that point. Otherwise start from the start.

            begin
              event_count += process_stream(group, stream,
                                            state.store[group][stream]['token'],
                                            @event_start_time, state)
            rescue Aws::CloudWatchLogs::Errors::InvalidParameterException
              metric(:increment, 'api.calls.getlogevents.invalid_token')
              log.error('cloudwatch token is expired or broken. '\
                        'trying with timestamp.')

              # try again with timestamp instead of forward token
              begin
                timestamp = state.store[group][stream]['timestamp']
                timestamp = @event_start_time unless timestamp

                event_count += process_stream(group, stream,
                                              nil, timestamp, state)
              rescue => boom
                log.error("Unable to retrieve events for stream #{stream} "\
                          "in group #{group}: #{boom.inspect}") # rubocop:disable all
                metric(:increment, 'api.calls.getlogevents.failed')
                sleep @error_interval
                next
              end
            rescue => boom
              log.error("Unable to retrieve events for stream #{stream} in group #{group}: #{boom.inspect}") # rubocop:disable LineLength
              metric(:increment, 'api.calls.getlogevents.failed')
              sleep @error_interval
              next
            end
          end
        end

        log.info('Saving state')
        begin
          state.save
          state.close
        rescue => boom
          log.error("Unable to save state file: #{boom.inspect}")
        end

        if event_count > 0
          sleep_interval = @interval
        else
          sleep_interval = @error_interval # when there is no events, slow down
        end

        log.info("#{event_count} events processed.")
        log.info("Pausing for #{sleep_interval}")
        sleep sleep_interval
      end
    end

    class CloudwatchIngestInput::State
      class LockFailed < RuntimeError; end
      attr_accessor :statefile, :store, :new_store

      def initialize(filepath, log)
        @filepath = filepath
        @log = log
        @store = Hash.new { |h, k| h[k] = Hash.new { |x, y| x[y] = {} } }
        @new_store = Hash.new { |h, k| h[k] = Hash.new { |x, y| x[y] = {} } }

        if File.exist?(filepath)
          self.statefile = Pathname.new(@filepath).open('r+')
        else
          @log.warn("No state file #{statefile} Creating a new one.")
          begin
            self.statefile = Pathname.new(@filepath).open('w+')
            save
          rescue => boom
            @log.error("Unable to create new file #{statefile.path}: "\
                       "#{boom.inspect}")
          end
        end

        # Attempt to obtain an exclusive flock on the file and raise and
        # exception if we can't
        @log.info("Obtaining exclusive lock on state file #{statefile.path}")
        lockstatus = statefile.flock(File::LOCK_EX | File::LOCK_NB)
        raise CloudwatchIngestInput::State::LockFailed if lockstatus == false

        begin
          @store.merge!(Psych.safe_load(statefile.read))

          # Migrate old state file
          @store.each do |_group, streams|
            streams.update(streams) do |_name, stream|
              if stream.is_a? String
                return { 'token' => stream, 'timestamp' => Time.now.to_i }
              end
              return stream
            end
          end

          @log.info("Loaded #{@store.keys.size} groups from #{statefile.path}")
        rescue
          statefile.close
          raise
        end
      end

      def save
        statefile.rewind
        statefile.truncate(0)
        statefile.write(Psych.dump(@new_store))
        @log.info("Saved state to #{statefile.path}")
        statefile.rewind
      end

      def close
        statefile.close
      end
    end
  end
end
