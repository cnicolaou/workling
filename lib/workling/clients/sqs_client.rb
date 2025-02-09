require 'workling/clients/base'
require 'json'
require 'right_aws'

#
#  An SQS client
#
# Requires the following configuration in workling.yml:
#
# production:
#   sqs_options:
#     aws_access_key_id: <your AWS access key id>
#     aws_secret_access_key: <your AWS secret access key>
#
# You can also add the following optional parameters:
#
#     # Queue names consist of an optional prefix, followed by the environment
#     # and the name of the key.
#     prefix: foo_
#
#     # The number of SQS messages to retrieve at once. The maximum and default
#     # value is 10.
#     messages_per_req: 10
#
#     # The SQS visibility timeout for retrieved messages. Defaults to 30 seconds.
#     visibility_timeout: 30
#
#     # The number of seconds to reserve for deleting a message from the qeueue.
#     # If buffered messages are getting too close to the visibility timeout,
#     # we drop them so they will get picked up the next time a worker retrieves
#     # messages, in order to avoid duplicate processing.
#     visibility_reserve: 10
#
#     # Below are various retry and timeout settings for the underlying right_aws
#     # and right_http_connection libraries. You may want to tweak these based on
#     # your workling usage. I recommend fairly low values, as large values can
#     # cause your Rails actions to hang in case of SQS issues.
#
#     # Maximum number of seconds to retry high level SQS errors. right_aws
#     # automatically retries using exponential back-off.
#     aws_reiteration_time: 2
#
#     # Low-level HTTP retry / timeout settings.
#     http_retry_count: 2
#     http_retry_delay: 1
#     http_open_timeout: 2
#     http_read_timeout: 10
#
module Workling
  module Clients
    class SqsClient < Workling::Clients::Base

      AWS_MAX_QUEUE_NAME = 80

      # Note that 10 is the maximum number of messages that can be retrieved
      # in a single request.
      DEFAULT_MESSAGES_PER_REQ = 10
      DEFAULT_VISIBILITY_TIMEOUT = 30
      DEFAULT_VISIBILITY_RESERVE = 10

      # Default right_aws and right_http_connection retry / timeout settings.
      AWS_REITERATION_TIME = 2
      HTTP_RETRY_COUNT = 2
      HTTP_RETRY_DELAY = 1
      HTTP_OPEN_TIMEOUT = 2
      HTTP_READ_TIMEOUT = 10

      # Mainly exposed for testing purposes
      attr_reader :sqs_options
      attr_reader :messages_per_req
      attr_reader :visibility_timeout

      # Starts the client.
      def connect
        @sqs_options = Workling.config[:sqs_options]

        # Make sure that required options were specified
        unless (@sqs_options.include?('aws_access_key_id') &&
               @sqs_options.include?('aws_secret_access_key'))
          raise WorklingError, 'Unable to start SqsClient due to missing SQS options'
        end

        # Optional settings
        @messages_per_req = @sqs_options['messages_per_req'] || DEFAULT_MESSAGES_PER_REQ
        @visibility_timeout = @sqs_options['visibility_timeout'] || DEFAULT_VISIBILITY_TIMEOUT
        @visibility_reserve = @sqs_options['visibility_reserve'] || DEFAULT_VISIBILITY_RESERVE

        begin
          # Set right_aws / right_http_connection settings based on custom
          # options or default values.
          RightAws::AWSErrorHandler::reiteration_time = @sqs_options['aws_reiteration_time'] || AWS_REITERATION_TIME
          new_http_params = Rightscale::HttpConnection::params.dup
          new_http_params[:http_connection_retry_count] = @sqs_options['http_retry_count'] || HTTP_RETRY_COUNT
          new_http_params[:http_connection_retry_delay] = @sqs_options['http_retry_delay'] || HTTP_RETRY_DELAY
          new_http_params[:http_connection_open_timeout] = @sqs_options['http_open_timeout'] || HTTP_OPEN_TIMEOUT
          new_http_params[:http_connection_read_timeout] = @sqs_options['http_read_timeout'] || HTTP_READ_TIMEOUT
          Rightscale::HttpConnection::params = new_http_params

          @sqs = RightAws::SqsGen2.new(
            @sqs_options['aws_access_key_id'],
            @sqs_options['aws_secret_access_key'],
            :multi_thread => true)
        rescue => e
          raise WorklingError, "Unable to connect to SQS. Error: #{e}"
        end
      end

      # No need for explicit closing, since there is no persistent
      # connection to SQS.
      def close
        true
      end

      # Retrieve work.
      def retrieve(key)
        begin
          # We're using a buffer per key to retrieve several messages at once,
          # then return them one at a time until the buffer is empty.
          # Workling seems to create one thread per worker class, each with its own
          # client. But to be sure (and to be less dependent on workling internals),
          # we store each buffer in a thread local variable.
          buffer = Thread.current["buffer_#{key}"]
          if buffer.nil? || buffer.empty?
            Thread.current["buffer_#{key}"] = buffer = queue_for_key(key).receive_messages(
              @messages_per_req, @visibility_timeout)
          end

          if buffer.empty?
            nil
          else
            msg = buffer.shift

            # We need to protect against the case that processing one of the
            # messages in the buffer took so much time that the visibility
            # timeout for the remaining messages has expired. To be on the
            # safe side (since we need to leave enough time to delete the
            # message), we drop it if more than half of the visibility timeout
            # has elapsed.
            if msg.received_at < (Time.now - (@visibility_timeout - @visibility_reserve))
              nil
            else
              # Need to wrap in HashWithIndifferentAccess, as JSON serialization
              # loses symbol keys.
              parsed_msg = HashWithIndifferentAccess.new(JSON.parse(msg.body))

              # Delete the msg from SQS, so we don't re-retrieve it after the
              # visibility timeout. Ideally we would defer deleting a msg until
              # after Workling has successfully processed it, but it currently
              # doesn't provide the necessary hooks for this.
              msg.delete

              parsed_msg
            end
          end

        rescue => e
          logger.error "Error retrieving msg for key: #{key}; Error: #{e}\n#{e.backtrace.join("\n")}"
        end

      end

      # Request work.
      def request(key, value)
        begin
          Thread.new { queue_for_key(key).send_message(value.to_json) }
        rescue => e
          logger.error "SQS Client: Error sending msg for key: #{key}, value: #{value.inspect}; Error: #{e}"
          raise WorklingError, "Error sending msg for key: #{key}, value: #{value.inspect}; Error: #{e}"
        end
      end

      # Returns the queue that corresponds to the specified key. Creates the
      # queue if it doesn't exist yet.
      def queue_for_key(key)
        # Use thread local for storing queues, for the same reason as for buffers
        Thread.current["queue_#{key}"] ||= @sqs.queue(queue_name(key), true, @visibility_timeout)
      end

      # Returns the queue name for the specified key. The name consists of an
      # optional prefix, followed by the environment and the key itself. Note
      # that with a long worker class / method name, the name could exceed the
      # 80 character maximum for SQS queue names. We truncate the name until it
      # fits, but there's still the danger of this not being unique any more.
      # Might need to implement a more robust naming scheme...
      def queue_name(key)
        "#{@sqs_options['prefix'] || ''}#{env}_#{key}"[0, AWS_MAX_QUEUE_NAME]
      end

      private

      def logger
        Rails.logger
      end

      def env
        Rails.env
      end
    end
  end
end