# frozen_string_literal: true

require_relative "test_helper"

class BaseServiceTest < Minitest::Test
  class SuccessfulService < Service::Base
    def call
      append_message("done")
      @value * 2
    end
  end

  class FailingService < Service::Base
    def call
      append_error(:invalid, "Invalid value")
      nil
    end
  end

  class MemoizingService < Service::Base
    def call
      value * 2
    end

    private

    def value
      @memoized_value ||= @value
    end
  end

  def test_exposes_a_version
    assert_match(/\A\d+\.\d+\.\d+\z/, Service::VERSION)
  end

  def test_executes_a_service
    result = SuccessfulService.call(value: 21)

    assert_equal 42, result.result
    assert_equal ["done"], result.messages
    assert_empty result.errors
    assert_predicate result, :successful?
    assert_predicate result, :frozen?
    assert_predicate result.errors, :frozen?
    assert_predicate result.messages, :frozen?
  end

  def test_collects_structured_errors
    result = FailingService.call
    error = result.errors.first

    refute_predicate result, :successful?
    assert_equal :invalid, error.type
    assert_equal "Invalid value", error.message
    assert_match(/base_service_test\.rb/, error.caller_info)
  end

  def test_allows_instance_variable_memoization_during_execution
    result = MemoizingService.call(value: 21)

    assert_equal 42, result.result
  end

  def test_builds_the_callback_collection_from_the_configuration_block
    service = SuccessfulService.new(value: 21) do |callbacks|
      callbacks.success { |value| value }
    end

    assert_instance_of CallbackCollection, service.instance_variable_get(:@callbacks)
    assert_predicate service.instance_variable_get(:@callbacks), :frozen?
  end
end
