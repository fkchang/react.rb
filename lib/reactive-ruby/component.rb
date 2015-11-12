require "reactive-ruby/ext/string"
require 'active_support/core_ext/class/attribute'
require 'reactive-ruby/callbacks'
require "reactive-ruby/ext/hash"
require "reactive-ruby/rendering_context"
require "reactive-ruby/observable"
require "reactive-ruby/state"

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
        end unless method_defined? :render

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
            unless name and name.method_defined? :render
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
        return component if component and component.method_defined? :render
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

    module ClassMethods

      def backtrace(*args)
        @backtrace_off = (args[0] == :off)
      end

      def process_exception(e, component, reraise = nil)
        message = ["Exception raised while rendering #{component}"]
        if !@backtrace_off
          message << "    #{e.backtrace[0]}"
          message += e.backtrace[1..-1].collect { |line| line }
        else
          message[0] += ": #{e.message}"
        end
        message = message.join("\n")
        `console.error(message)`
        raise e if reraise
      end

      def validator
        @validator ||= React::Validator.new
      end

      def prop_types
        if self.validator
          {
            _componentValidator: %x{
              function(props, propName, componentName) {
                var errors = #{validator.validate(Hash.new(`props`))};
                var error = new Error(#{"In component `" + self.name + "`\n" + `errors`.join("\n")});
                return #{`errors`.count > 0 ? `error` : `undefined`};
              }
            }
          }
        else
          {}
        end
      end

      def default_props
        validator.default_props
      end

      def params(&block)
        validator.build(&block)
      end

      def define_param_method(name, param_type)
        if param_type == React::Observable
          (@two_way_params ||= []) << name
          define_method("#{name}") do
            params[name].instance_variable_get("@value") if params[name]
          end
          define_method("#{name}!") do |*args|
            return unless params[name]
            if args.count > 0
              current_value = params[name].instance_variable_get("@value")
              params[name].call args[0]
              current_value
            else
              current_value = params[name].instance_variable_get("@value")
              params[name].call current_value unless @dont_update_state rescue nil # rescue in case we in middle of render
              params[name]
            end
          end
        elsif param_type == Proc
          define_method("#{name}") do |*args, &block|
            params[name].call(*args, &block) if params[name]
          end
        else
          define_method("#{name}") do
            @processed_params[name] ||= if param_type.respond_to? :_react_param_conversion
              param_type._react_param_conversion params[name]
            elsif param_type.is_a? Array and param_type[0].respond_to? :_react_param_conversion
              params[name].collect { |param| param_type[0]._react_param_conversion param }
            else
              params[name]
            end
          end
        end
      end

      def required_param(name, options = {})
        validator.requires(name, options)
        define_param_method(name, options[:type])
      end

      alias_method :require_param, :required_param

      def optional_param(name, options = {})
        validator.optional(name, options)
        define_param_method(name, options[:type]) unless name == :params
      end

      def collect_other_params_as(name)
        validator.all_others(name)
        define_method(name) do
          @_all_others ||= self.class.validator.collect_all_others(params)
        end
      end

      def define_state(*states, &block)
        default_initial_value = (block and block.arity == 0) ? yield : nil
        states_hash = (states.last.is_a? Hash) ? states.pop : {}
        states.each { |name| states_hash[name] = default_initial_value }
        (self.initial_state ||= {}).merge! states_hash
        states_hash.each do |name, initial_value|
          define_state_methods(self, name, &block)
        end
      end

      def export_state(*states, &block)
        default_initial_value = (block and block.arity == 0) ? yield : nil
        states_hash = (states.last.is_a? Hash) ? states.pop : {}
        states.each { |name| states_hash[name] = default_initial_value }
        React::State.initialize_states(self, states_hash)
        states_hash.each do |name, initial_value|
          define_state_methods(self, name, self, &block)
          define_state_methods(singleton_class, name, self, &block)
        end
      end

      def define_state_methods(this, name, from = nil, &block)
        this.define_method("#{name}") do
          React::State.get_state(from || self, name)
        end
        this.define_method("#{name}=") do |new_state|
          yield name, React::State.get_state(from || self, name), new_state if block and block.arity > 0
          React::State.set_state(from || self, name, new_state)
        end
        this.define_method("#{name}!") do |*args|
          #return unless @native
          if args.count > 0
            yield name, React::State.get_state(from || self, name), args[0] if block and block.arity > 0
            current_value = React::State.get_state(from || self, name)
            React::State.set_state(from || self, name, args[0])
            current_value
          else
            current_state = React::State.get_state(from || self, name)
            yield name, React::State.get_state(from || self, name), current_state if block and block.arity > 0
            React::State.set_state(from || self, name, current_state)
            React::Observable.new(current_state) do |update|
              yield name, React::State.get_state(from || self, name), update if block and block.arity > 0
              React::State.set_state(from || self, name, update)
            end
          end
        end
      end

      def native_mixin(item)
        native_mixins << item
      end

      def native_mixins
        @native_mixins ||= []
      end

      def static_call_back(name, &block)
        static_call_backs[name] = block
      end

      def static_call_backs
        @static_call_backs ||= {}
      end

      def export_component(opts = {})
        export_name = (opts[:as] || name).split("::")
        first_name = export_name.first
        Native(`window`)[first_name] = add_item_to_tree(Native(`window`)[first_name], [React::API.create_native_react_class(self)] + export_name[1..-1].reverse).to_n
      end

      def add_item_to_tree(current_tree, new_item)
        if Native(current_tree).class != Native::Object or new_item.length == 1
          new_item.inject do |memo, sub_name| {sub_name => memo} end
        else
          Native(current_tree)[new_item.last] = add_item_to_tree(Native(current_tree)[new_item.last], new_item[0..-2])
          current_tree
        end
      end

    end

    module API

      def dom_node
        if `typeof React.findDOMNode === 'undefined'`
          `#{self}.native.getDOMNode`            # v0.12.0
        else
          `React.findDOMNode(#{self}.native)`    # v0.13.0
        end
      end

      def mounted?
        `#{self}.native.isMounted()`
      end

      def force_update!
        `#{self}.native.forceUpdate()`
      end

      def set_props(prop, &block)
        raise "No native ReactComponent associated" unless @native
        %x{
          #{@native}.setProps(#{prop.shallow_to_n}, function(){
            #{block.call if block}
          });
        }
      end

      def set_props!(prop, &block)
        raise "No native ReactComponent associated" unless @native
        %x{
          #{@native}.replaceProps(#{prop.shallow_to_n}, function(){
            #{block.call if block}
          });
        }
      end

      def set_state(state, &block)
        raise "No native ReactComponent associated" unless @native
        %x{
          #{@native}.setState(#{state.shallow_to_n}, function(){
            #{block.call if block}
          });
        }
      end

      def set_state!(state, &block)
        raise "No native ReactComponent associated" unless @native
        %x{
          #{@native}.replaceState(#{state.shallow_to_n}, function(){
            #{block.call if block}
          });
        }
      end
    end

  end
end
