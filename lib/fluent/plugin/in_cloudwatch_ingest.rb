require 'aws-sdk'
require 'fluent/config/error'
require 'fluent/plugin/input'
require 'fluent/plugin/parser'
require 'json'
require 'pathname'
require 'psych'

module Fluent::Plugin
  class CloudwatchIngestInput < Fluent::Plugin::Input
    Fluent::Plugin.register_input('cloudwatch_ingest_chaeyk', self)
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
    desc 'State file name'
    config_param :state_file_name, :string, default: '/var/spool/td-agent/cloudwatch.state' # rubocop:disable all
    desc 'Fetch logs every interval'
    config_param :interval, :time, default: 60
    desc 'Time to pause between API call failures and limits'
    config_param :api_interval, :time, default: 5
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
    config_section :parse do
      config_set_default :@type, 'cloudwatch_ingest_chaeyk'
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

        log.info("Using STS for authentication with source account ARN: #{@sts_arn}, session name: #{@sts_session_name}") # rubocop:disable all
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
      end
    end

    def log_groups(log_group_prefix)
      log_groups = []

      # Fetch all log group names
      next_token = nil
      loop do
        begin
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

          response.log_groups.each { |g| log_groups << g.log_group_name }
          break unless response.next_token
          next_token = response.next_token
        rescue => boom
          log.error("Unable to retrieve log groups: #{boom.inspect}")
          next_token = nil
          sleep @api_interval
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
          log.error("Unable to retrieve log streams for group #{log_group_name} with stream prefix #{log_stream_name_prefix}: #{boom.inspect}") # rubocop:disable all
          log_streams = []
          next_token = nil
          sleep @api_interval
          retry
        end
      end
      log.info("Found #{log_streams.size} streams for #{log_group_name}")

      return log_streams
    end

    def run
      until @finished
        begin
          state = State.new(@state_file_name, log)
        rescue => boom
          log.info("Failed lock state. Sleeping for #{@interval}: #{boom.inspect}")
          sleep @interval
          next
        end

        event_count = 0

        # Fetch the streams for each log group
        log_groups(@log_group_name_prefix).each do |group|
          # For each log stream get and emit the events
          log_streams(group, @log_stream_name_prefix).each do |stream|
            if ! state.store[group][stream]
              state.store[group][stream] = {}
            end

            # See if we have some stored state for this group and stream.
            # If we have then use the stored forward_token to pick up
            # from that point. Otherwise start from the start.
            if state.store[group][stream]['token']
              stream_token = state.store[group][stream]['token']
            else
              stream_token = nil
            end

            if state.store[group][stream]['timestamp']
              stream_timestamp = state.store[group][stream]['timestamp']
            else
              stream_timestamp = @event_start_time
            end

            begin
              response = @aws.get_log_events(
                log_group_name: group,
                log_stream_name: stream,
                next_token: stream_token,
                limit: @limit_events,
                start_time: @event_start_time,
                start_from_head: @oldest_logs_first
              )

              response.events.each do |e|
                begin
                  emit(e, group, stream)
                  event_count = event_count + 1
                rescue => boom
                  log.error("Failed to emit event #{e}: #{boom.inspect}")
                end
              end

              # Once all events for this stream have been processed,
              # in this iteration, store the forward token
              state.store[group][stream]['token'] = response.next_forward_token
              state.store[group][stream]['timestamp'] = response.events.last ? response.events.last.timestamp : stream_timestamp
            rescue Aws::CloudWatchLogs::Errors::InvalidParameterException => boom
              log.error("cloudwatch token is expired or broken. trying with timestamp.");

              # try again with timestamp instead of forward token
              begin
                response = @aws.get_log_events(
                  log_group_name: group,
                  log_stream_name: stream,
                  limit: @limit_events,
                  start_time: stream_timestamp,
                  start_from_head: true
                )

                response.events.each do |e|
                  begin
                    emit(e, group, stream)
                    event_count = event_count + 1
                  rescue => boom
                    log.error("Failed to emit event #{e}: #{boom.inspect}")
                  end
                end

                # Once all events for this stream have been processed,
                # in this iteration, store the forward token
                state.store[group][stream]["token"] = response.next_forward_token
                state.store[group][stream]['timestamp'] = response.events.last ? response.events.last.timestamp : steam_timestamp
              rescue => boom
                log.error("Unable to retrieve events for stream #{stream} in group #{group}: #{boom.inspect}") # rubocop:disable all
                sleep @api_interval
                next
              end
            rescue => boom
              log.error("Unable to retrieve events for stream #{stream} in group #{group}: #{boom.inspect}") # rubocop:disable all
              sleep @api_interval
              next
            end
          end
        end

        log.info('Pruning and saving state')
        state.prune(log_groups(@log_group_name_prefix)) # Remove dead streams
        begin
          state.save
          state.close
        rescue
          log.error("Unable to save state file: #{boom.inspect}")
        end

        if event_count > 0
          sleep_interval = @interval
        else
          sleep_interval = @api_interval # when there is no events, slow down
        end

        log.info("#{event_count} events processed.")
        log.info("Pausing for #{sleep_interval}")
        sleep sleep_interval
      end
    end

    class CloudwatchIngestInput::State
      class LockFailed < RuntimeError; end
      attr_accessor :statefile, :store

      def initialize(filepath, log)
        @filepath = filepath
        @log = log
        @store = Hash.new { |h, k| h[k] = Hash.new { |h1, k1| h1[k1] = {} } }

        if File.exist?(filepath)
          self.statefile = Pathname.new(@filepath).open('r+')
        else
          @log.warn("No state file #{statefile} Creating a new one.")
          begin
            self.statefile = Pathname.new(@filepath).open('w+')
            save
          rescue => boom
            @log.error("Unable to create new file #{statefile.path}: #{boom.inspect}")
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
          @store.each { |group, streams|
            streams.update(streams) { |name, stream|
              (stream.is_a? String) ? { 'token' => stream, 'timestamp' => Time.now.to_i } : stream
            }
          }

          @log.info("Loaded #{@store.keys.size} groups from #{statefile.path}")
        rescue
          statefile.close
          raise
        end
      end

      def save
        statefile.rewind
        statefile.truncate(0)
        statefile.write(Psych.dump(@store))
        @log.info("Saved state to #{statefile.path}")
        statefile.rewind
      end

      def close
        statefile.close
      end

      def prune(log_groups)
        groups_before = @store.keys.size
        @store.delete_if { |k, _v| true unless log_groups.include?(k) }
        @log.info("Pruned #{groups_before - @store.keys.size} keys from store")

        # TODO: also prune streams as these are most likely to be transient
      end
    end
  end
end
