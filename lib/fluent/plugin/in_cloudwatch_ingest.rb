require 'fluent/plugin/input'
require 'fluent/plugin/parser'
require 'fluent/config/error'
require 'aws-sdk'
require 'pathname'
require 'psych'

module Fluent::Plugin
  class CloudwatchIngestInput < Fluent::Plugin::Input
    Fluent::Plugin.register_input('cloudwatch_ingest', self)
    helpers :compat_parameters

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
    desc 'Time to pause between API call failures'
    config_param :api_interval, :time, default: 120

    def initialize
      super
      log.info('Starting fluentd-plugin-cloudwatch-ingest')
    end

    def configure(conf)
      super
      log.info('Configured fluentd-plugin-cloudwatch-ingest')
    end

    def start
      super
      log.info('Started fluentd-plugin-cloudwatch-ingest')

      # Get a handle to Cloudwatch
      aws_options = {}
      Aws.config[:region] = @region
      Aws.config[:logger] = log
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

    def emit(log_event)
      log.warn(log_event)
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
          log.error("Unable to retrieve log groups: #{boom}")
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
          log.error("Unable to retrieve log streams for group #{log_group_name} with stream prefix #{log_stream_name_prefix}: #{boom}") # rubocop:disable all
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
          log.info("Failed lock state. Sleeping for #{@interval}: #{boom}")
          sleep @interval
          retry
        end

        # Fetch the streams for each log group
        log_groups(@log_group_name_prefix).each do |group|
          # For each log stream get and emit the events
          log_streams(group, @log_stream_name_prefix).each do |stream|
            # See if we have some stored state for this group and stream.
            # If we have then use the stored forward_token to pick up
            # from that point. Otherwise start from the start.
            if state.store[group] && state.store[group][stream]
              stream_token =
                (state.store[group][stream] if state.store[group][stream])
            else
              stream_token = nil
            end

            begin
              loop do
                response = @aws.get_log_events(
                  log_group_name: group,
                  log_stream_name: stream,
                  next_token: stream_token
                )

                emit(response.events)
                break unless response.next_token
                stream_token = response.next_token
              end

              # Once all events for this stream have been processed,
              # store the forward token
              state.store[group][stream] = response.next_forward_token
            rescue => boom
              log.error("Unable to retrieve events for stream
                #{stream} in group #{group}: #{boom}")
              sleep @api_interval
              retry
            end
          end
        end

        log.info('Pruning and saving state')
        state.prune(log_groups) # Remove dead streams
        begin
          state.save
          state.close
        rescue
          log.error("Unable to save state file: #{boom}")
        end
        log.info("Pausing for #{@interval}")
        sleep @interval
      end
    end

    class CloudwatchIngestInput::State
      class LockFailed < RuntimeError; end
      attr_accessor :statefile, :store

      def initialize(filepath, log)
        @filepath = filepath
        @log = log
        @store = {}

        if File.exist?(filepath)
          self.statefile = Pathname.new(@filepath).open('r+')
        else
          @log.warn("No state file #{statefile} Creating a new one.")
          begin
            self.statefile = Pathname.new(@filepath).open('w+')
            save
          rescue => boom
            @log.error("Unable to create new state file #{statefile}: #{boom}")
          end
        end

        # Attempt to obtain an exclusive flock on the file and raise and
        # exception if we can't
        @log.info("Obtaining exclusive lock on state file #{statefile}")
        lockstatus = statefile.flock(File::LOCK_EX | File::LOCK_NB)
        raise CloudwatchIngestInput::State::LockFailed if lockstatus == false

        @store.merge!(Psych.safe_load(statefile.read))
        @log.info("Loaded #{@store.keys.size} log groups from #{statefile}")
      end

      def save
        statefile.rewind
        statefile.write(Psych.dump(@store))
        @log.info("Saved state to #{statefile}")
        statefile.rewind
      end

      def close
        statefile.close
      end

      def prune(log_groups)
        groups_before = @store.keys.size
        @store.delete_if { |k, _v| true unless log_groups.key?(k) }
        @log.info("Pruned #{groups_before - keys.size} keys from state file")

        # TODO: also prune streams as these are most likely to be transient
      end
    end
  end
end
