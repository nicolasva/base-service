# Base Service

[![Build Status](https://github.com/nicolasva/base-service/actions/workflows/ci.yml/badge.svg)](https://github.com/nicolasva/base-service/actions/workflows/ci.yml)
[![Code Climate](https://codeclimate.com/github/nicolasva/base-service.svg)](https://codeclimate.com/github/nicolasva/base-service)
[![Gem Version](https://badge.fury.io/rb/base-service.svg)](https://rubygems.org/gems/base-service)
[![Documentation Status](https://img.shields.io/badge/docs-RubyDoc.info-blue.svg)](https://www.rubydoc.info/gems/base-service)
[![Downloads](https://img.shields.io/gem/dt/base-service.svg?style=flat)](https://rubygems.org/gems/base-service)

`base-service` provides a lightweight base class for building Ruby service
objects with a consistent interface:

- keyword arguments become instance variables;
- business logic is defined in a zero-argument `call` method;
- errors and messages are collected during execution;
- every call returns a `Service::Result`;
- named callbacks can be configured through
  [`callback-collection`](https://github.com/nicolasva/callback-collection).

## Installation

Add the gem to your application's `Gemfile`:

```ruby
gem "base-service"
```

Then install the dependencies:

```sh
bundle install
```

In a Ruby application that does not use Bundler, require the gem explicitly:

```ruby
require "base_service"
```

Rails normally loads the gem automatically when it is declared in the
`Gemfile`.

## Creating a service

A service inherits from `Service::Base` and implements a public, zero-argument
`call` method:

```ruby
class DoubleValueService < Service::Base
  def call
    return append_error(:missing_value, "Value is required") unless @value

    append_message("Value doubled")
    @value * 2
  end
end
```

Keyword arguments passed to the service are automatically exposed as instance
variables. In this example, `value: 21` becomes `@value`.

```ruby
result = DoubleValueService.call(value: 21)
```

There is no need to define an initializer in every service.

## Call results

`MyService.call(...)` does not return the business value directly. It always
returns a `Service::Result`:

```ruby
result = DoubleValueService.call(value: 21)

result.result      # => 42
result.successful? # => true
result.errors      # => []
result.messages    # => ["Value doubled"]
```

| Method | Description |
|---|---|
| `result.result` | The value returned by the service's `call` method |
| `result.errors` | Errors appended during execution |
| `result.messages` | Messages appended during execution |
| `result.successful?` | `true` when `result.errors` is empty |

The `Service::Result` object and its `errors` and `messages` arrays are frozen
after execution. The business value stored in `result.result` is not
automatically frozen.

## Adding errors

The protected `append_error(type, message)` method adds a `Service::Error` to
the result:

```ruby
class CreateUserService < Service::Base
  def call
    unless @user.save
      @user.errors.messages.each do |type, messages|
        append_error(type, messages)
      end
    end

    @user
  end
end
```

```ruby
result = CreateUserService.call(user: user)

result.successful? # => false when at least one error was appended

error = result.errors.first
error.type         # => :email
error.message      # => ["has already been taken"]
error.caller_info  # => location where append_error was called
```

The gem does not transform the error type or message. They can therefore use
values supplied directly by Rails or by the application's domain.

`append_error` only records an error. It does not raise an exception or stop
the service automatically. Use `return` when execution must stop:

```ruby
def call
  unless valid?
    append_error(:invalid, "The operation is invalid")
    return nil
  end

  perform_operation
end
```

Exceptions raised by business logic, Active Record, or a callback are not
rescued by `Service::Base`. They propagate to the caller normally.

## Adding messages

The protected `append_message(message)` method adds non-blocking information
to the result:

```ruby
class ImportUserService < Service::Base
  def call
    user = User.create!(@attributes)
    append_message("User #{user.id} imported")
    user
  end
end
```

```ruby
result = ImportUserService.call(attributes: { email: "ruby@example.com" })

result.successful? # => true
result.messages    # => ["User 42 imported"]
result.result      # => a User instance
```

Adding a message does not affect `successful?`.

## Rails service example

A service can use Active Record models, Rails helpers, and private methods like
any other Ruby object:

```ruby
module Billing
  class DiscountedPriceService < Service::Base
    include ActionView::Helpers::NumberHelper

    def call
      return 0 unless customer.discount_enabled?
      return 0 unless customer.discount_percentage.present?

      calculate_discounted_price
    end

    private

    def calculate_discounted_price
      discount =
        customer.discount_percentage.to_f / 100 * @original_price

      return @original_price if discount < customer.minimum_discount.to_f

      unit_price = catalog.price_for(product)
      return @original_price if unit_price.blank?

      if product.sold_in_whole_units?
        (discount / unit_price).truncate * unit_price
      else
        discount
      end
    end

    def catalog
      @catalog ||= @order.store.catalog
    end

    def customer
      @customer ||= @order.customer
    end

    def product
      @product ||= @order.products.first
    end
  end
end
```

Call the service with keyword arguments:

```ruby
result = Billing::DiscountedPriceService.call(
  original_price: 10_000,
  order: order
)

if result.successful?
  discounted_price = result.result
else
  Rails.logger.error(result.errors.map(&:message))
end
```

The service instance remains mutable during execution. Memoization with `||=`,
such as `@customer ||= ...`, therefore works as expected.

## Order creation example

```ruby
module Orders
  class CreateOrderService < Service::Base
    def call
      order = create_order
      create_invoice_for(order)
      order
    end

    private

    def create_order
      order = Order.new(
        customer_id: @customer.id,
        product_id: @product.id,
        quantity: @quantity
      )

      unless order.save
        order.errors.messages.each do |type, messages|
          append_error(type, messages)
        end
      end

      order
    end

    def create_invoice_for(order)
      return unless order.persisted?

      invoice = Invoice.new(
        order: order,
        customer: order.customer,
        total: order.total
      )

      return if invoice.save

      append_error(
        :invoice_creation_failed,
        "Invoice could not be created for order #{order.id}"
      )
    end
  end
end
```

```ruby
result = Orders::CreateOrderService.call(
  customer: customer,
  product: product,
  quantity: 2
)

order = result.result

if result.successful?
  redirect_to order_path(order)
else
  flash.now[:alert] = result.errors.map(&:message).join(", ")
end
```

The service returns the order in `result.result` even when errors were
appended. Use `result.successful?` to determine whether the execution was
successful.

## Calling a service from another service

A service can call another service. Check the returned `Service::Result` and
retrieve its business value explicitly:

```ruby
class CheckoutService < Service::Base
  def call
    order_result =
      Orders::CreateOrderService.call(
        customer: @customer,
        product: @product,
        quantity: @quantity
      )

    unless order_result.successful?
      order_result.errors.each do |error|
        append_error(error.type, error.message)
      end

      return nil
    end

    order_result.result
  end
end
```

Errors from a nested service are not copied automatically to the calling
service. The example above propagates them explicitly.

## Using a service in a Rails controller

```ruby
class OrdersController < ApplicationController
  def create
    result =
      Orders::CreateOrderService.call(
        customer: current_customer,
        product: product,
        quantity: params[:quantity]
      )

    if result.successful?
      redirect_to order_path(result.result), notice: "Order created"
    else
      flash.now[:alert] = result.errors.map(&:message).join(", ")
      render :new, status: :unprocessable_entity
    end
  end
end
```

## Callbacks

The block passed to `.call` or `.new` builds an immutable callback collection
provided by the `callback-collection` gem:

```ruby
class NotifyUserService < Service::Base
  def call
    user = User.find(@user_id)
    @callbacks&.respond_with(:success, user)
    user
  rescue ActiveRecord::RecordNotFound => error
    append_error(:not_found, error.message)
    @callbacks&.respond_with(:failure, error)
    nil
  end
end
```

```ruby
result = NotifyUserService.call(user_id: 42) do |callbacks|
  callbacks.success do |user|
    UserMailer.notification(user).deliver_later
  end

  callbacks.failure do |error|
    Rails.logger.warn(error.message)
  end
end
```

Callbacks are not invoked automatically by `Service::Base`. The service
decides when to invoke them:

```ruby
@callbacks.respond_with(:callback_name, argument)
```

The safe navigation operator (`&.`) makes the callback block optional. Without
it, the service must be called with the expected callback.

The collection is frozen after configuration. Invoking an unknown callback
raises `NoMethodError`, and exceptions raised inside callbacks propagate to
the caller.

See the
[`callback-collection`](https://github.com/nicolasva/callback-collection)
documentation for method-based callback registration and Ractor
compatibility.

## Manual instantiation

The recommended form is:

```ruby
result = MyService.call(argument: value)
```

It is equivalent to:

```ruby
service = MyService.new(argument: value)
result = service.execute
```

In both cases, `execute` creates a new execution context, invokes the business
`call` method, and builds a `Service::Result`.

Avoid reusing the same instance for multiple calls to `execute`.
`MyService.call(...)` creates a dedicated instance for each execution.

## Development

```sh
bundle install
bundle exec rake
```

The default task runs the test suite and then builds the gem in `pkg/`.

## Publishing to RubyGems

Releases use
[RubyGems Trusted Publishing](https://guides.rubygems.org/trusted-publishing/).
No RubyGems API key needs to be stored in GitHub secrets.

Configure a trusted publisher for the gem on RubyGems with the following
values:

- gem: `base-service`;
- repository owner: `nicolasva`;
- repository: `base-service`;
- workflow: `release.yml`;
- GitHub environment: leave blank.

Publish a version by creating a tag that exactly matches `Service::VERSION`:

```sh
VERSION=$(ruby -Ilib -rbase_service/version -e 'print Service::VERSION')
git tag "v${VERSION}"
git push origin "v${VERSION}"
```

GitHub Actions then builds and publishes the gem to RubyGems. RubyDoc
automatically generates documentation for the published version.
