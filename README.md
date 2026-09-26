# Base Service

[![Build Status](https://github.com/nicolasva/base-service/actions/workflows/ci.yml/badge.svg)](https://github.com/nicolasva/base-service/actions/workflows/ci.yml)
[![Code Climate](https://codeclimate.com/github/nicolasva/base-service.svg)](https://codeclimate.com/github/nicolasva/base-service)
[![Gem Version](https://badge.fury.io/rb/base-service.svg)](https://rubygems.org/gems/base-service)
[![Documentation Status](https://img.shields.io/badge/docs-RubyDoc.info-blue.svg)](https://www.rubydoc.info/gems/base-service)
[![Downloads](https://img.shields.io/gem/dt/base-service.svg?style=flat)](https://rubygems.org/gems/base-service)

`base-service` fournit une classe de base légère pour construire des services
Ruby avec une interface commune :

- les paramètres nommés deviennent des variables d'instance ;
- la logique métier est définie dans une méthode `call` sans argument ;
- les erreurs et les messages sont collectés pendant l'exécution ;
- chaque appel retourne un objet `Service::Result` ;
- des callbacks nommés peuvent être configurés grâce à
  [`callback-collection`](https://github.com/nicolasva/callback-collection).

## Installation

Ajoutez la gem au `Gemfile` de l'application :

```ruby
gem "base-service"
```

Puis installez les dépendances :

```sh
bundle install
```

Dans une application Ruby sans Bundler, chargez explicitement la gem :

```ruby
require "base_service"
```

Rails charge normalement la gem automatiquement lorsqu'elle est déclarée dans
le `Gemfile`.

## Créer un service

Un service hérite de `Service::Base` et implémente une méthode publique `call`
sans argument :

```ruby
class DoubleValueService < Service::Base
  def call
    return append_error(:missing_value, "Value is required") unless @value

    append_message("Value doubled")
    @value * 2
  end
end
```

Les arguments nommés transmis au service sont automatiquement disponibles sous
forme de variables d'instance. Ici, `value: 21` devient `@value`.

```ruby
result = DoubleValueService.call(value: 21)
```

Il n'est pas nécessaire d'écrire un constructeur dans chaque service.

## Résultat d'un appel

`MonService.call(...)` ne retourne pas directement la valeur métier. Il
retourne toujours un `Service::Result` :

```ruby
result = DoubleValueService.call(value: 21)

result.result      # => 42
result.successful? # => true
result.errors      # => []
result.messages    # => ["Value doubled"]
```

| Méthode | Description |
|---|---|
| `result.result` | Valeur retournée par la méthode `call` du service |
| `result.errors` | Tableau des erreurs ajoutées pendant l'exécution |
| `result.messages` | Tableau des messages ajoutés pendant l'exécution |
| `result.successful?` | `true` lorsque `result.errors` est vide |

L'objet `Service::Result` ainsi que ses tableaux `errors` et `messages` sont
gelés après l'exécution. La valeur métier contenue dans `result.result` n'est
pas gelée automatiquement.

## Ajouter des erreurs

La méthode protégée `append_error(type, message)` ajoute un objet
`Service::Error` au résultat :

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

result.successful? # => false si au moins une erreur a été ajoutée

error = result.errors.first
error.type         # => :email
error.message      # => ["has already been taken"]
error.caller_info  # => emplacement où append_error a été appelé
```

Le type et le message ne sont pas transformés par la gem. Ils peuvent donc
reprendre directement les valeurs fournies par Rails ou par le domaine métier.

`append_error` enregistre uniquement l'erreur : il ne lève pas d'exception et
n'arrête pas automatiquement le service. Utilisez `return` lorsque l'exécution
doit s'arrêter :

```ruby
def call
  unless valid?
    append_error(:invalid, "The operation is invalid")
    return nil
  end

  perform_operation
end
```

Les exceptions levées par la logique métier, Active Record ou un callback ne
sont pas interceptées. Elles remontent normalement à l'appelant.

## Ajouter des messages

La méthode protégée `append_message(message)` ajoute une information non
bloquante au résultat :

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
result.result      # => instance de User
```

Ajouter un message ne modifie pas la valeur de `successful?`.

## Exemple avec un service Rails

Le service peut utiliser des modèles Active Record, des helpers Rails et des
méthodes privées comme n'importe quel objet Ruby :

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

Appel du service :

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

L'instance du service reste mutable pendant l'exécution. Les mémorisations
avec `||=`, comme `@customer ||= ...`, fonctionnent donc normalement.

## Exemple de création d'une commande

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

Le service retourne la commande dans `result.result`, même si des erreurs
ont été ajoutées. C'est `result.successful?` qui indique si l'exécution est
considérée comme réussie.

## Utilisation dans un autre service

Un service peut appeler un autre service. Il faut vérifier le
`Service::Result` retourné et récupérer explicitement sa valeur métier :

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

Les erreurs d'un sous-service ne sont pas automatiquement copiées dans le
service appelant. L'exemple ci-dessus les propage explicitement.

## Utilisation dans un contrôleur Rails

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

Le bloc transmis à `.call` ou `.new` construit une collection de callbacks
immuable fournie par la gem `callback-collection` :

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

Les callbacks ne sont pas exécutés automatiquement par `Service::Base`. Le
service choisit quand les appeler avec :

```ruby
@callbacks.respond_with(:nom_du_callback, argument)
```

L'opérateur `&.` permet de rendre le bloc de callbacks facultatif. Sans `&.`,
le service doit être appelé avec le callback attendu.

La collection est gelée après sa configuration. Un callback inconnu provoque
une `NoMethodError`, et une exception levée dans un callback remonte à
l'appelant.

Consultez la documentation de
[`callback-collection`](https://github.com/nicolasva/callback-collection) pour
les callbacks enregistrés par méthode et la compatibilité avec les Ractors.

## Instanciation manuelle

La forme recommandée est :

```ruby
result = MyService.call(argument: value)
```

Elle équivaut à :

```ruby
service = MyService.new(argument: value)
result = service.execute
```

Dans les deux cas, `execute` crée un nouveau contexte d'exécution, appelle la
méthode métier `call`, puis construit un `Service::Result`.

Évitez de réutiliser une même instance avec plusieurs appels à `execute`. La
forme `MyService.call(...)` crée une instance dédiée pour chaque exécution.

## Développement

```sh
bundle install
bundle exec rake
```

La tâche par défaut exécute les tests puis construit la gem dans `pkg/`.

## Publication sur RubyGems

Les versions sont publiées avec
[RubyGems Trusted Publishing](https://guides.rubygems.org/trusted-publishing/).
Aucune clé API RubyGems ne doit être ajoutée aux secrets GitHub.

Avant la première publication, créez un **Pending Trusted Publisher** dans
votre profil RubyGems avec les paramètres suivants :

- gem : `base-service` ;
- propriétaire du dépôt : `nicolasva` ;
- dépôt : `base-service` ;
- workflow : `release.yml` ;
- environnement GitHub : `release`.

Publiez ensuite une version en créant un tag correspondant exactement à
`Service::VERSION` :

```sh
VERSION=$(ruby -Ilib -rbase_service/version -e 'print Service::VERSION')
git tag "v${VERSION}"
git push origin "v${VERSION}"
```

Le workflow GitHub Actions construit alors la gem et la publie sur RubyGems.
RubyDoc génère automatiquement la documentation de la version publiée.
