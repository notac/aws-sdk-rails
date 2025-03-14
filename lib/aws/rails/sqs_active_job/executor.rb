# frozen_string_literal: true

require 'aws-sdk-sqs'
require 'concurrent'

module Aws
  module Rails
    module SqsActiveJob
      # CLI runner for polling for SQS ActiveJobs
      class Executor

        DEFAULTS = {
           min_threads:     0,
           max_threads:     Concurrent.processor_count,
           auto_terminate:  true,
           idletime:        60, # 1 minute
           fallback_policy: :caller_runs # slow down the producer thread
        }.freeze

        def initialize(options = {})
          @executor = Concurrent::ThreadPoolExecutor.new(DEFAULTS.merge(options))
          # Monitor threads used to refresh visiblity
          @visibility_refresh = options.delete(:visibility_refresh)
          @monitor = Concurrent::ThreadPoolExecutor.new(DEFAULTS.merge(options)) if @visibility_refresh
          @logger = options[:logger] || ActiveSupport::Logger.new(STDOUT)
        end

        # TODO: Consider catching the exception and sleeping instead of using :caller_runs
        def execute(message)
          # Used to tell the visibilty refresh thread to give up
          refresh_monitor = true
          @executor.post(message) do |message|
            begin
              job = JobRunner.new(message)
              @logger.info("Running job: #{job.id}[#{job.class_name}]")
              job.run
              message.delete
            rescue Aws::Json::ParseError => e
              @logger.error "Unable to parse message body: #{message.data.body}. Error: #{e}."
            rescue StandardError => e
              # message will not be deleted and will be retried
              job_msg = job ? "#{job.id}[#{job.class_name}]" : 'unknown job'
              @logger.info "Error processing job #{job_msg}: #{e}"
              @logger.debug e.backtrace.join("\n")
            ensure
              refresh_monitor = false
            end
          end
          refresh_monitor(message, refresh_monitor) if @visibility_refresh
        end

        def refresh_monitor(message, refresh_monitor)
          @monitor.post(message) do |message|
            while refresh_monitor
              begin
                # Extend the visibility timeout to the provided refresh timeout
                message.change_visibility({ visibility_timeout: @visibility_refresh })
                # Wait half the refresh timeout, and repeat
                sleep(@visibility_refresh / 2.0)
              rescue Aws::SQS::Errors::ReceiptHandleIsInvalid
                # Message has been deleted. We don't care!
                break
              rescue Aws::SQS::Errors::MessageNotInflight
                # Message has been otherwise released. We don't care!
                break
              rescue => e
                # If anything else goes wrong, we should log and break the loop.
                @logger.error("Monitor process failed for message: #{message.id}. Error: #{e}")
                break
              end
            end
          end
        end

        def shutdown(timeout=nil)
          @executor.shutdown
          clean_shutdown = @executor.wait_for_termination(timeout)
          if clean_shutdown
            @logger.info 'Clean shutdown complete.  All executing jobs finished.'
          else
            @logger.info "Timeout (#{timeout}) exceeded.  Some jobs may not have"\
              " finished cleanly.  Unfinished jobs will not be removed from"\
              " the queue and can be ru-run once their visibility timeout"\
              " passes."
          end
        end
      end
    end
  end
end
