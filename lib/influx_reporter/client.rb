# frozen_string_literal: true

require 'thread'
require 'influx_reporter/subscriber'
require 'influx_reporter/influx_db_client'
require 'influx_reporter/worker'
require 'influx_reporter/transaction'
require 'influx_reporter/trace'
require 'influx_reporter/error_message'
require 'influx_reporter/event_message'
require 'influx_reporter/data_builders'

module InfluxReporter
  # @api private
  class Client
    include Logging

    KEY = :__influx_reporter_transaction_key
    LOCK = Mutex.new

    class TransactionInfo
      def current
        Thread.current[KEY]
      end

      def current=(transaction)
        Thread.current[KEY] = transaction
      end
    end

    # life cycle

    def self.inst
      @instance
    end

    def self.start!(config = nil)
      return @instance if @instance

      LOCK.synchronize do
        return @instance if @instance
        @instance = new(config).start!
      end
    end

    def self.stop!
      LOCK.synchronize do
        return unless @instance

        @instance.stop!
        @instance = nil
      end
    end

    def initialize(config)
      @config = config

      @influx_client = InfluxDBClient.new config
      @queue = Queue.new

      @data_builders = Struct.new(:transactions, :error_message, :event).new(
          DataBuilders::Transactions.new(config),
          DataBuilders::Error.new(config),
          DataBuilders::Event.new(config)
      )

      unless config.disable_performance
        @transaction_info = TransactionInfo.new
        @subscriber = Subscriber.new config, self
      end

      @pending_transactions = []
      @last_sent_transactions = Time.now.utc
    end

    # @!attribute [r] config
    #   InfluxReporter configuration
    #   @return [InfluxReporter::Configuration]
    # @!attribute [r] queue
    #   Worker data queue
    #   @return [Thread::Queue]
    # @!attribute [r] pending_transactions
    #   Transaction to be submitted
    #   @return [Thread::Queue]
    attr_reader :config, :queue, :pending_transactions

    # Start client
    # @return [InfluxReporter::Client]
    def start!
      info 'Starting client'

      @subscriber&.register!

      self
    end

    def stop!
      flush_transactions
      kill_worker
      unregister! if @subscriber
    end

    at_exit do
      stop!
    end

    # metrics

    def current_transaction
      @transaction_info.current
    end

    def current_transaction=(transaction)
      @transaction_info.current = transaction
    end

    def transaction(endpoint, kind = nil, result = nil)
      if config.disable_performance
        return yield if block_given?
        return nil
      end

      if current_transaction
        transaction = current_transaction
        yield transaction if block_given?
        return transaction
      end

      transaction = Transaction.new self, endpoint, kind, result

      self.current_transaction = transaction
      return transaction unless block_given?

      begin
        yield transaction
      ensure
        self.current_transaction = nil
        transaction.done
      end

      transaction
    end

    def trace(*args, &block)
      if config.disable_performance
        return yield if block_given?
        return nil
      end

      unless transaction = current_transaction
        return yield if block_given?
        return
      end

      transaction.trace(*args, &block)
    end

    def submit_transaction(transaction)
      ensure_worker_running

      if config.debug_traces
        unless transaction.endpoint == 'Rack'
          debug { Util::Inspector.new.transaction transaction, include_parents: true }
        end
      end

      @pending_transactions << transaction

      flush_transactions if should_send_transactions?
    end

    def flush_transactions
      return if @pending_transactions.empty?

      data = @data_builders.transactions.build(@pending_transactions)
      enqueue Worker::PostRequest.new(resource_from_path('transactions', {}), data)

      @last_sent_transactions = Time.now.utc
      @pending_transactions = []

      true
    end

    def flush_transactions_if_needed
      if should_send_transactions?
        flush_transactions
      end
    end

    # errors

    def set_context(context)
      @context = context
    end

    def with_context(context)
      current = @context

      set_context((current || {}).deep_merge(context))

      yield if block_given?
    ensure
      set_context(current)
    end

    def report(exception, opts = {})
      return if config.disable_errors
      return unless exception

      ensure_worker_running

      exception.set_backtrace caller unless exception.backtrace

      if error_message = ErrorMessage.from_exception(config, exception, opts)
        error_message.add_extra(@context) if @context
        data = @data_builders.error_message.build error_message
        enqueue Worker::PostRequest.new(resource_from_path('errors', opts), data)
      end
    end

    def report_message(message, opts = {})
      return if config.disable_errors

      ensure_worker_running

      error_message = ErrorMessage.new(config, message, opts)
      error_message.add_extra(@context) if @context
      data = @data_builders.error_message.build error_message
      enqueue Worker::PostRequest.new(resource_from_path('errors', opts), data)
    end

    def report_event(message, opts = {})
      ensure_worker_running

      event = EventMessage.new(config, message, opts)
      event.add_extra(@context) if @context
      data = @data_builders.event.build event
      enqueue Worker::PostRequest.new(resource_from_path('events', opts), data)
    end

    def capture
      unless block_given?
        return Kernel.at_exit do
          if $ERROR_INFO
            debug $ERROR_INFO.inspect
            report $ERROR_INFO
          end
        end
      end

      begin
        yield
      rescue Error => e
        raise # Don't capture InfluxReporter errors
      rescue Exception => e
        report e
        raise
      end
    end

    private

    def enqueue(request)
      @queue << request
    end

    def resource_from_path(path, opts)
      obj = { url: "/#{path}/" }
      obj[:database] = opts[:database] if opts[:database]
      obj
    end


    def start_worker
      return if worker_running?

      return if config.disable_worker

      info 'Starting worker in thread'

      @worker_thread = Thread.new do
        begin
          Worker.new(config, @queue, @influx_client).run
        rescue => e
          fatal "Failed booting worker:\n#{e.inspect}"
          debug e.backtrace.join("\n")
          raise
        end
      end
    end

    def kill_worker
      return unless worker_running?
      @queue << Worker::StopMessage.new
      unless @worker_thread.join(config.worker_quit_timeout)
        error 'Failed to wait for worker, not all messages sent'
      end
      @worker_thread = nil
    end

    def ensure_worker_running
      return if worker_running?

      LOCK.synchronize do
        return if worker_running?
        start_worker
      end
    end

    def worker_running?
      @worker_thread&.alive?
    end

    def unregister!
      @subscriber.unregister!
    end

    def should_send_transactions?
      return true if config.transaction_post_interval.nil?

      Time.now.utc - @last_sent_transactions > config.transaction_post_interval
    end
  end
end
