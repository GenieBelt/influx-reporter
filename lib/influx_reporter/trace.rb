# frozen_string_literal: true

require 'influx_reporter/util'

module InfluxReporter
  class Trace
    DEFAULT_KIND = 'code.custom'

    def initialize(transaction, signature, kind = nil, parents = [], extra = nil)
      @transaction = transaction
      @signature = signature
      @kind = kind || DEFAULT_KIND
      @parents = parents || []
      @extra = extra || {}

      @timestamp = Util.nanos
    end

    attr_accessor :signature, :kind, :parents, :extra
    attr_reader :transaction, :timestamp, :duration, :relative_start, :start_time

    def start(relative_to)
      @start_time = Util.nanos
      @relative_start = start_time - relative_to

      @transaction._trace_started self
      self
    end

    def done(ms = Util.nanos)
      @duration = ms - start_time

      @transaction._trace_stopped self
      self
    end

    def done?
      !!duration
    end

    def running?
      !done?
    end

    def inspect
      info = %w[signature kind parents extra timestamp duration relative_start]
      "<Trace #{info.map { |m| "#{m}:#{send(m).inspect}" }.join(' ')}>"
    end
  end
end
