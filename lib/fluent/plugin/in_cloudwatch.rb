require 'fluent/plugin/input'
require 'fluent/plugin/parser'
require 'fluentd/config/error'
require 'aws-sdk'
require 'pathname'
require 'yaml'

module Fluent::Plugin
  class Cloudwatch < Input
    Fluent::Plugin.register_input('cloudwatch', self)
    helpers :parser, :compat_parameters

    desc 'The region of the source cloudwatch logs'
    config_param :region, :string
    desc 'Enable STS for cross-account IAM'
    config_param :sts_enabled, :bool, default: false
    desc 'The IAM role ARN in the source account to use when STS is enabled'
    config_param :sts_arn, :string
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
  end

  def initialize
    super
  end

  def configure(conf)
    super
    configure_parser(conf)
  end

  def start
    # Get a handle to Cloudwatch
    aws_options = {}
    Aws.config[:region] = @region
    if @sts_enabled
      aws_options[:credentials] = Aws::AssumeRoleCredentials.new(
        role_arn: @sts_arn,
        role_session_name: @sts_session_name
      )

      log.info("Using STS for authentication with source account ARN:
        #{@sts_arn}, session name: #{@sts_session_name}")
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

  def configure_parser(conf)
    if conf[:format] # rubocop:disable all
      @parser = Fluent::TextParser.new
      @parser.configure(conf)
    end
  end

  def emit(log_event)
    # TODO: I need to do something useful
  end

  def log_groups(log_group_prefix)
    log_groups = []

    # Fetch all log group names
    next_token = nil
    loop do
      begin
        response = @aws.describe_log_groups(
          log_group_name_prefix: log_group_prefix,
          next_token: next_token
        )

        response.log_groups.each { |g| log_groups << g.log_group_name }
        break unless response.next_token
        next_token = response.next_token
      rescue => boom
        log.error("Unable to retrieve log groups: #{boom}")
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
        response = @aws.describe_log_streams(
          log_group_name: group,
          log_stream_name_prefix: log_stream_name_prefix,
          next_token: next_token
        )

        response.log_streams.each { |s| log_streams << s.log_stream_name }
        break unless reponse.next_token
        next_token = reponse.next_token
      rescue => boom
        log.error("Unable to retrieve log streams for group #{group}
          with stream prefix #{log_stream_name_prefix}: #{boom}")
      end
    end
    log.info("Found #{log_streams.size} streams for #{log_group_name}")

    return log_streams
  end

  def run
    until @finished
      begin
        state = State.new(@state_file_name)
      rescue Cloudwatch::State::LockFailed
        log.info("Failed to obtain state lock. Sleeping for #{@interval}")
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
          stream_token = (state[group][stream] if state[group][stream])

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
            state[group][stream] = response.next_forward_token
          rescue => boom
            log.error("Unable to retrieve events for stream
              #{stream} in group #{group}: #{boom}")
          end
        end
      end

      log.info('Pruning and saving state')
      state.prune(log_groups) # Remove dead streams
      state.save
      state.close
      log.info("Pausing for #{@interval}")
      sleep @interval
    end
  end

  class Cloudwatch::State < Hash
    class LockFailed < RuntimeError; end
    attr_accessor :statefile

    def initialize(filepath)
      self.statefile = Pathname.new(filepath).open('w')
      unless statefile.exists?
        log.warn("State file #{statefile} does not exist. Creating a new one.")
        begin
          save
        rescue => boom
          log.error("Unable to create new state file #{statefile}: #{boom}")
        end
      end

      # Attempt to obtain an exclusive flock on the file and raise and
      # exception if we can't
      log.info("Obtaining exclusive lock on state file #{statefile}")
      lockstatus = statefile.flock(File::LOCK_EX | File::LOCK_NB)
      raise Cloudwatch::State::LockFailed if lockstatus == false

      begin
        merge!(YAML.safe_load(statefile.read))
        log.info("Loaded state for #{keys.size} log groups from #{statefile}")
      rescue => boom
        log.error("Unable to read state file #{statefile}: #{boom}")
      end
    end

    def save
      statefile.write(self)
      log.info("Saved state to #{statefile}")
    rescue => boom
      log.error("Unable to write state file #{statefile}: #{boom}")
    end

    def close
      statefile.close
    end

    def prune(log_groups)
      groups_before = keys.size
      delete_if { |k, _v| true unless log_groups.key?(k) }
      log.info("Pruned #{groups_before - keys.size} keys from state file")

      # TODO: also prune streams as these are most likely to be transient
    end
  end
end
