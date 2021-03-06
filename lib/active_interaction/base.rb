# coding: utf-8

require 'active_support/core_ext/hash/indifferent_access'

module ActiveInteraction
  # @abstract Subclass and override {#execute} to implement a custom
  #   ActiveInteraction::Base class.
  #
  # Provides interaction functionality. Subclass this to create an interaction.
  #
  # @example
  #   class ExampleInteraction < ActiveInteraction::Base
  #     # Required
  #     boolean :a
  #
  #     # Optional
  #     boolean :b, default: false
  #
  #     def execute
  #       a && b
  #     end
  #   end
  #
  #   outcome = ExampleInteraction.run(a: true)
  #   if outcome.valid?
  #     outcome.result
  #   else
  #     outcome.errors
  #   end
  class Base
    include ActiveModelable
    include Runnable

    validate :input_errors

    class << self
      include Hashable
      include Missable

      # @!method run(inputs = {})
      #   @note If the interaction inputs are valid and there are no runtime
      #     errors and execution completed successfully, {#valid?} will always
      #     return true.
      #
      #   Runs validations and if there are no errors it will call {#execute}.
      #
      #   @param (see ActiveInteraction::Base#initialize)
      #
      #   @return [Base]

      # @!method run!(inputs = {})
      #   Like {.run} except that it returns the value of {#execute} or raises
      #     an exception if there were any validation errors.
      #
      #   @param (see ActiveInteraction::Base.run)
      #
      #   @return (see ActiveInteraction::Runnable::ClassMethods#run!)
      #
      #   @raise (see ActiveInteraction::Runnable::ClassMethods#run!)

      # @!method transaction(enable, options = {})
      #   Configure transactions by enabling or disabling them and setting
      #   their options.
      #
      #   @example Disable transactions
      #     Class.new(ActiveInteraction::Base) do
      #       transaction false
      #     end
      #
      #   @example Use different transaction options
      #     Class.new(ActiveInteraction::Base) do
      #       transaction true, isolation: :serializable
      #     end
      #
      #   @param enable [Boolean] Should transactions be enabled?
      #   @param options [Hash] Options to pass to
      #     `ActiveRecord::Base.transaction`.
      #
      #   @return [nil]
      #
      #   @since 1.2.0

      # Get or set the description.
      #
      # @example
      #   core.desc
      #   # => nil
      #   core.desc('Description!')
      #   core.desc
      #   # => "Description!"
      #
      # @param desc [String, nil] What to set the description to.
      #
      # @return [String, nil] The description.
      def desc(desc = nil)
        if desc.nil?
          unless instance_variable_defined?(:@_interaction_desc)
            @_interaction_desc = nil
          end
        else
          @_interaction_desc = desc
        end

        @_interaction_desc
      end

      # Get all the filters defined on this interaction.
      #
      # @return [Hash{Symbol => Filter}]
      def filters
        @_interaction_filters ||= {}
      end

      # @private
      def method_missing(*args, &block)
        super do |klass, names, options|
          fail InvalidFilterError, 'missing attribute name' if names.empty?

          names.each { |name| add_filter(klass, name, options, &block) }
        end
      end

      private

      # @param klass [Class]
      # @param name [Symbol]
      # @param options [Hash]
      def add_filter(klass, name, options, &block)
        fail InvalidFilterError, name.inspect if InputProcessor.reserved?(name)

        initialize_filter(klass.new(name, options, &block))
      end

      # Import filters from another interaction.
      #
      # @param klass [Class] The other interaction.
      # @param options [Hash]
      #
      # @option options [Array<Symbol>, nil] :only Import only these filters.
      # @option options [Array<Symbol>, nil] :except Import all filters except
      #   for these.
      #
      # @return (see .filters)
      #
      # @!visibility public
      def import_filters(klass, options = {})
        only = options[:only]
        except = options[:except]

        other_filters = klass.filters.dup
        other_filters.select! { |k, _| [*only].include?(k) } if only
        other_filters.reject! { |k, _| [*except].include?(k) } if except

        other_filters.values.each { |filter| initialize_filter(filter) }
      end

      # @param klass [Class]
      def inherited(klass)
        klass.instance_variable_set(:@_interaction_filters, filters.dup)

        super
      end

      # @param filter [Filter]
      def initialize_filter(filter)
        filters[filter.name] = filter

        attr_accessor filter.name
        define_method("#{filter.name}?") { !public_send(filter.name).nil? }

        filter.default if filter.default?
      end
    end

    # @param inputs [Hash{Symbol => Object}] Attribute values to set.
    #
    # @private
    def initialize(inputs = {})
      fail ArgumentError, 'inputs must be a hash' unless inputs.is_a?(Hash)

      process_inputs(inputs.symbolize_keys)
    end

    # Returns the column object for the named filter.
    #
    # @param name [Symbol] The name of a filter.
    #
    # @example
    #   class Interaction < ActiveInteraction::Base
    #     string :email, default: nil
    #
    #     def execute; end
    #   end
    #
    #   Interaction.new.column_for_attribute(:email)
    #   # => #<ActiveInteraction::FilterColumn:0x007faebeb2a6c8 @type=:string>
    #
    #   Interaction.new.column_for_attribute(:not_a_filter)
    #   # => nil
    #
    # @return [FilterColumn, nil]
    #
    # @since 1.2.0
    def column_for_attribute(name)
      filter = self.class.filters[name]
      FilterColumn.intern(filter.database_column_type) if filter
    end

    # @!method compose(other, inputs = {})
    #   Run another interaction and return its result. If the other interaction
    #     fails, halt execution.
    #
    #   @param other (see ActiveInteraction::Runnable#compose)
    #   @param inputs (see ActiveInteraction::Base#initialize)
    #
    #   @return (see ActiveInteraction::Base.run!)

    # @!method execute
    #   @abstract
    #
    #   Runs the business logic associated with the interaction. This method is
    #   only run when there are no validation errors. The return value is
    #   placed into {#result}. By default, this method is run in a transaction
    #   if ActiveRecord is available (see {.transaction}).
    #
    #   @raise (see ActiveInteraction::Runnable#execute)

    # Returns the inputs provided to {.run} or {.run!} after being cast based
    #   on the filters in the class.
    #
    # @return [Hash{Symbol => Object}] All inputs passed to {.run} or {.run!}.
    def inputs
      self.class.filters.keys.each_with_object({}) do |name, h|
        h[name] = public_send(name)
      end
    end

    private

    # @param inputs [Hash{Symbol => Object}]
    def process_inputs(inputs)
      inputs.each do |key, value|
        fail InvalidValueError, key.inspect if InputProcessor.reserved?(key)

        populate_reader(key, value)
      end

      populate_filters(InputProcessor.process(inputs))
    end

    def populate_reader(key, value)
      instance_variable_set("@#{key}", value) if respond_to?(key)
    end

    def populate_filters(inputs)
      self.class.filters.each do |name, filter|
        begin
          public_send("#{name}=", filter.clean(inputs[name]))
        rescue InvalidValueError, MissingValueError, InvalidNestedValueError
          # Validators (#input_errors) will add errors if appropriate.
        end
      end
    end

    # @!group Validations

    def input_errors
      Validation.validate(self.class.filters, inputs).each do |error|
        errors.add_sym(*error)
      end
    end
  end
end
