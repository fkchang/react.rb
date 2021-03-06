require 'react/ext/string'
require 'react/ext/hash'
require 'active_support/core_ext/class/attribute'
require 'react/callbacks'
require 'react/rendering_context'
require 'react/observable'
require 'react/state'
require 'react/component/api'
require 'react/component/class_methods'
require 'native'

module React
  module Component
    def self.included(base)
      base.include(API)
      base.include(React::Callbacks)
      base.class_eval do
        class_attribute :initial_state
        define_callback :before_mount
        define_callback :after_mount
        define_callback :before_receive_props
        define_callback :before_update
        define_callback :after_update
        define_callback :before_unmount

        def render
          raise "no render defined"
        end unless method_defined?(:render)

        def children
          nodes = [`#{@native}.props.children`].flatten
          class << nodes
            include Enumerable

            def to_n
              self
            end

            def each(&block)
              if block_given?
                %x{
                  React.Children.forEach(#{self.to_n}, function(context){
                    #{block.call(React::Element.new(`context`))}
                  })
                }
                nil
              else
                Enumerator.new(`React.Children.count(#{self.to_n})`) do |y|
                  %x{
                    React.Children.forEach(#{self.to_n}, function(context){
                      #{y << React::Element.new(`context`)}
                    })
                  }
                end
              end
            end
          end

          nodes
        end

      end
      base.extend(ClassMethods)

      if base.name
        parent = base.name.split("::").inject([Module]) { |nesting, next_const| nesting + [nesting.last.const_get(next_const)] }[-2]

        class << parent

          def method_missing(n, *args, &block)
            name = n
            if name =~ /_as_node$/
              node_only = true
              name = name.gsub(/_as_node$/, "")
            end
            begin
              name = const_get(name)
            rescue Exception
              name = nil
            end
            unless name && name.method_defined?(:render)
              return super
            end
            if node_only
              React::RenderingContext.build { React::RenderingContext.render(name, *args, &block) }.to_n
            else
              React::RenderingContext.render(name, *args, &block)
            end
          end

        end
      end
    end

    def initialize(native_element)
      @native = native_element
    end

    def params
      Hash.new(`#{@native}.props`)
    end

    def refs
      Hash.new(`#{@native}.refs`)
    end

    def state
      raise "No native ReactComponent associated" unless @native
      Hash.new(`#{@native}.state`)
    end

    def update_react_js_state(object, name, value)
      if object
        set_state({"***_state_updated_at-***" => Time.now.to_f, "#{object.class.to_s+'.' unless object == self}#{name}" => value})
      else
        set_state({name => value})
      end rescue nil
    end

    def emit(event_name, *args)
      self.params["_on#{event_name.to_s.event_camelize}"].call(*args)
    end

    def component_will_mount
      IsomorphicHelpers.load_context(true) if IsomorphicHelpers.on_opal_client?
      @processed_params = {}
      set_state! initial_state if initial_state
      React::State.initialize_states(self, initial_state)
      React::State.set_state_context_to(self) { self.run_callback(:before_mount) }
    rescue Exception => e
      self.class.process_exception(e, self)
    end

    def component_did_mount
      React::State.set_state_context_to(self) do
        self.run_callback(:after_mount)
        React::State.update_states_to_observe
      end
    rescue Exception => e
      self.class.process_exception(e, self)
    end

    def component_will_receive_props(next_props)
      # need to rethink how this works in opal-react, or if its actually that useful within the react.rb environment
      # for now we are just using it to clear processed_params
      React::State.set_state_context_to(self) { self.run_callback(:before_receive_props, Hash.new(next_props)) }
      @processed_params = {}
    rescue Exception => e
      self.class.process_exception(e, self)
    end

    def props_changed?(next_props)
      return true unless params.keys.sort == next_props.keys.sort
      params.detect { |k, v| `#{next_props[k]} != #{params[k]}`}
    end

    def should_component_update?(next_props, next_state)
      React::State.set_state_context_to(self) do
        next_props = Hash.new(next_props)
        if self.respond_to?(:needs_update?)
          !!self.needs_update?(next_props, Hash.new(next_state))
        elsif false # switch to true to force updates per standard react
          true
        elsif props_changed? next_props
          true
        elsif `!next_state != !#{@native}.state`
          true
        elsif `!next_state && !#{@native}.state`
          false
        elsif `next_state["***_state_updated_at-***"] != #{@native}.state["***_state_updated_at-***"]`
          true
        else
          false
        end.to_n
      end
    end

    def component_will_update(next_props, next_state)
      React::State.set_state_context_to(self) { self.run_callback(:before_update, Hash.new(next_props), Hash.new(next_state)) }
    rescue Exception => e
      self.class.process_exception(e, self)
    end

    def component_did_update(prev_props, prev_state)
      React::State.set_state_context_to(self) do
        self.run_callback(:after_update, Hash.new(prev_props), Hash.new(prev_state))
        React::State.update_states_to_observe
      end
    rescue Exception => e
      self.class.process_exception(e, self)
    end

    def component_will_unmount
      React::State.set_state_context_to(self) do
        self.run_callback(:before_unmount)
        React::State.remove
      end
    rescue Exception => e
      self.class.process_exception(e, self)
    end

    def p(*args, &block)
      if block || args.count == 0 || (args.count == 1 && args.first.is_a?(Hash))
        _p_tag(*args, &block)
      else
        Kernel.p(*args)
      end
    end

    def component?(name)
      name_list = name.split("::")
      scope_list = self.class.name.split("::").inject([Module]) { |nesting, next_const| nesting + [nesting.last.const_get(next_const)] }.reverse
      scope_list.each do |scope|
        component = name_list.inject(scope) do |scope, class_name|
          scope.const_get(class_name)
        end rescue nil
        return component if component && component.method_defined?(:render)
      end
      nil
    end

    def method_missing(n, *args, &block)
      return params[n] if params.key? n
      name = n
      if name =~ /_as_node$/
        node_only = true
        name = name.gsub(/_as_node$/, "")
      end
      unless (React::HTML_TAGS.include?(name) || name == 'present'  || name == '_p_tag' || (name = component?(name, self)))
        return super
      end

      if name == "present"
        name = args.shift
      end

      if name == "_p_tag"
        name = "p"
      end

      if node_only
        React::RenderingContext.build { React::RenderingContext.render(name, *args, &block) }.to_n
      else
        React::RenderingContext.render(name, *args, &block)
      end
    end

    def watch(value, &on_change)
      React::Observable.new(value, on_change)
    end

    def define_state(*args, &block)
      React::State.initialize_states(self, self.class.define_state(*args, &block))
    end

    attr_reader :waiting_on_resources

    def _render_wrapper
      React::State.set_state_context_to(self) do
        RenderingContext.render(nil) {render || ""}.tap { |element| @waiting_on_resources = element.waiting_on_resources if element.respond_to? :waiting_on_resources }
      end
    rescue Exception => e
      self.class.process_exception(e, self)
    end
  end
end
