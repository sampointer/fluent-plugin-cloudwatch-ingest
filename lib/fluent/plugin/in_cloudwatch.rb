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
    config_param :log_group_name_prefix, :string, default: ""
    desc 'Log stream name or prefix. Not setting means "all"'
    config_param :log_stream_name_prefix, :string, default: ""
    desc 'State file name'
    config_param :state_file_name, :string, default: '/var/spool/td-agent/cloudwatch.state'
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
    aws_options = Hash.new
    Aws.config[:region] = @region
    if @sts_enabled
      aws_options = [:credentials] = Aws::AssumeRoleCredentials.new(
              role_arn: @sts_arn,
              role_session_name: @sts_session_name
        )

      log.info("Using STS for authentication with source account ARN: #{@sts_arn}, session name: #{@sts_session_name}")
    else
      log.info("Using local instance IAM role for authentication")
    end
    @aws = Aws::CloudWatchLogs::Client.new(options)
    @finished = false
    @thread = Thread.new(&method(:run))
  end

  def shutdown
    @finished = true
    @thread.join
  end

  private
  def configure_parser(conf)
    if conf[:format]
      @parser = Fluent::TextParser.new
      @parser.configure(conf)
    end
  end

  def emit(log_event)
    # TODO: I need to do something useful
  end

  def run
    until @finished
      log_groups = Array.new
      state = State.new(@state_file_name)
      
      # Fetch all log group names
      next_token = nil
      while true do
        begin
          response = @aws.describe_log_groups({log_group_name_prefix: @log_group_name_prefix, next_token: next_token})
          response.log_groups.each { |g| log_groups << g.log_group_name }
          break unless response.next_token
          next_token = response.next_token
        rescue => boom
          log.error("Unable to retrieve log groups: #{boom}")
        end
      end
      log.info("Found #{log_groups.size} log groups")

      # Fetch the streams for each log group
      log_groups.each do |group|
        log_streams = Array.new
        next_token = nil
        while true do
          begin
            response = @aws.describe_log_streams({log_group_name: group, log_stream_name_prefix: @log_stream_name_prefix, next_token: next_token})
            response.log_streams.each { |s| log_streams << s.log_stream_name }
            break unless reponse.next_token
            next_token = reponse.next_token
          rescue => boom
            log.error("Unable to retrieve log streams for group #{group} with stream prefix #{@log_stream_name_prefix}: #{boom}")
          end
        end

        # For each log stream get and emit the events
        log_streams.each do |stream|
          # See if we have some stored state for this group and stream.
          # If we have then use the stored forward_token to pick up
          # from that point. Otherwise start from the start.
          if state[group][stream]
            stream_token = state[group][stream]
          else
            stream_token = nil
          end

          begin
            while true do
              response = @aws.get_log_events({log_group_name: group, log_stream_name: stream, next_token: stream_token})
              emit(response.events)
              break unless response.next_token
              stream_token = response.next_token
            end

            # Once all events for this stream have been processed, store the forward token
            state[group][stream] = response.next_forward_token
          rescue => boom
            log.error("Unable to retrieve events for stream #{stream} in group #{group}: #{boom}")
          end
        end
      end

      log.info("Pruning and saving state")
      state.prune(log_groups) # Remove any log groups and associated streams that no longer exist
      state.save
      log.info("Pausing for #{@interval}")
      sleep @interval
    end
  end

  class Cloudwatch::State < Hash
    attr_accessor :statefile

    def initialize(filepath)
      self.statefile = Pathname.new(filepath)
      unless self.statefile.exists?
        log.warn("State file #{self.statefile} does not exist. Creating a new one.")
        begin
          self.save
        rescue => boom
          log.error("Unable to create new state file #{self.statefile}: #{boom}")
        end
      end

      begin
        self.merge! = YAML.load(self.statefile.read)
        log.info("Loaded state for #{self.keys.size} log groups from #{self.statefile}"
      rescue => boom
        log.error("Unable to read state file #{statefile}: #{boom}")
      end
    end

    def save
      begin
        file = File.open(self.statefile, 'w')
        file.write(self)
        file.close
        log.info("Saved state to #{self.statefile}")
      rescue => boom
        log.error("Unable to write state file #{self.statefile}: #{boom}")
      end
    end

    def prune(log_groups)
      groups_before = self.keys.size
      self.delete_if { |k,v| true unless log_groups.key?(k) }
      log.info("Pruned #{before - self.keys.size} keys from state file")

      # TODO: also prune streams as these are most likely to be transient
    end
  end

end
