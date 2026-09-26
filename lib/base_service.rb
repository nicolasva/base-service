# frozen_string_literal: true

require "callback_collection"
require_relative "base_service/version"

module Service
  class Base
    def initialize(**args, &block)
      args.each { |key, value| instance_variable_set("@#{key}", value) }
      @callbacks = ::CallbackCollection.new(&block) if block
    end

    def self.call(**args, &block)
      new(**args, &block).execute
    end

    def execute
      @context = Context.new
      result_payload = call

      Result.new(result_payload, @context.errors, @context.messages)
    end

    protected

    def append_error(type, message)
      @context.append_error(type, message, caller.first)
    end

    def append_message(message)
      @context.append_message(message)
    end
  end

  class Context
    attr_reader :errors, :messages

    def initialize
      @errors = []
      @messages = []
    end

    def append_error(type, message, caller_info = caller.first)
      @errors << ::Service::Error.new(type, message, caller_info)
    end

    def append_message(message)
      @messages << message
    end
  end

  class Error
    attr_reader :type, :message, :caller_info

    def initialize(type, message, caller_info)
      @type = type
      @caller_info = caller_info
      @message = message
    end
  end

  class Result
    attr_reader :result, :errors, :messages

    def initialize(result, errors, messages)
      @result = result
      @errors = errors.dup.freeze
      @messages = messages.dup.freeze
      freeze
    end

    def successful?
      @errors.empty?
    end
  end
end
