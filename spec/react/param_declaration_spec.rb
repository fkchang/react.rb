require 'spec_helper'

if opal?
describe 'the param macro' do
  it "can create and access a required param" do
    stub_const 'Foo', Class.new(React::Component::Base)
    Foo.class_eval do
      param :foo

      def render
        div { params.foo }
      end
    end

    expect(React.render_to_static_markup(React.create_element(Foo, {foo: :bar}))).to eq('<div>bar</div>')
  end

  it "can create and access an optional params" do
    stub_const 'Foo', Class.new(React::Component::Base)
    Foo.class_eval do

      param foo1: :no_bar1
      param foo2: :no_bar2
      param :foo3, default: :no_bar3
      param :foo4, default: :no_bar4

      def render
        div { "#{params.foo1}-#{params.foo2}-#{params.foo3}-#{params.foo4}" }
      end
    end

    expect(React.render_to_static_markup(React.create_element(Foo, {foo1: :bar1, foo3: :bar3}))).to eq('<div>bar1-no_bar2-bar3-no_bar4</div>')
  end

  it 'can specify validation rules with the type option' do
    stub_const 'Foo', Class.new(React::Component::Base)
    Foo.class_eval do
      param :foo, type: String
    end

    expect(Foo.prop_types).to have_key(:_componentValidator)
  end

  it "can type check params" do
    stub_const 'Foo', Class.new(React::Component::Base)
    Foo.class_eval do

      param :foo1, type: String
      param :foo2, type: String

      def render
        div { "#{params.foo1}-#{params.foo2}" }
      end
    end

    expect(React.render_to_static_markup(React.create_element(Foo, {foo1: 12, foo2: "string"}))).to eq('<div>12-string</div>')
  end

  it 'logs error in warning if validation failed' do
    stub_const 'Lorem', Class.new
    stub_const 'Foo2', Class.new(React::Component::Base)
    Foo2.class_eval do
      param :foo
      param :lorem, type: Lorem
      param :bar, default: nil, type: String
      def render; div; end
    end

    %x{
      var log = [];
      var org_warn_console = window.console.warn;
      window.console.warn = function(str){log.push(str)}
    }
    renderToDocument(Foo2, bar: 10, lorem: Lorem.new)
    `window.console.warn = org_warn_console;`
    expect(`log`).to eq(["Warning: Failed propType: In component `Foo2`\nRequired prop `foo` was not specified\nProvided prop `bar` could not be converted to String"])
  end

  it 'should not log anything if validation passes' do
    stub_const 'Lorem', Class.new
    stub_const 'Foo', Class.new(React::Component::Base)
    Foo.class_eval do
      param :foo
      param :lorem, type: Lorem
      param :bar, default: nil, type: String

      def render; div; end
    end

    %x{
      var log = [];
      var org_warn_console = window.console.warn;
      window.console.warn = function(str){log.push(str)}
    }
    renderToDocument(Foo, foo: 10, bar: '10', lorem: Lorem.new)
    `window.console.warn = org_warn_console;`
    expect(`log`).to eq([])
  end

  describe 'advanced type handling' do
    before(:each) do
      %x{
        window.dummy_log = [];
        window.org_warn_console = window.console.warn;
        window.console.warn = function(str){window.dummy_log.push(str)}
      }
      stub_const 'Foo', Class.new(React::Component::Base)
      Foo.class_eval { def render; ""; end }
    end
    after(:each) do
      `window.console.warn = window.org_warn_console;`
    end

    it "can use the [] notation for arrays" do
      Foo.class_eval do
        param :foo, type: []
        param :bar, type: []
      end
      renderToDocument(Foo, foo: 10, bar: [10])
      expect(`window.dummy_log`).to eq(["Warning: Failed propType: In component `Foo`\nProvided prop `foo` could not be converted to Array"])
    end

    it "can use the [xxx] notation for arrays of a specific type" do
      Foo.class_eval do
        param :foo, type: [String]
        param :bar, type: [String]
      end
      renderToDocument(Foo, foo: [10], bar: ["10"])
      expect(`window.dummy_log`).to eq(["Warning: Failed propType: In component `Foo`\nProvided prop `foo`[0] could not be converted to String"])
    end

    it "can convert a json hash to a type" do
      stub_const "BazWoggle", Class.new
      BazWoggle.class_eval do
        def initialize(kind)
          @kind = kind
        end
        attr_accessor :kind
        def self._react_param_conversion(json, validate_only)
          new(json[:bazwoggle]) if json[:bazwoggle]
        end
      end
      Foo.class_eval do
        param :foo, type: BazWoggle
        param :bar, type: BazWoggle
        param :baz, type: [BazWoggle]
        def render
          "#{params.bar.kind}, #{params.baz[0].kind}"
        end
      end
      expect(React.render_to_static_markup(React.create_element(
        Foo, foo: "", bar: {bazwoggle: 1}, baz: [{bazwoggle: 2}]))).to eq('<span>1, 2</span>')
      expect(`window.dummy_log`).to eq(["Warning: Failed propType: In component `Foo`\nProvided prop `foo` could not be converted to BazWoggle"])
    end

    it "will alias a Proc type param" do
      Foo.class_eval do
        param :foo, type: Proc
        def render
          params.foo
        end
      end
      expect(React.render_to_static_markup(React.create_element(Foo, foo: lambda { 'works!' }))).to eq('<span>works!</span>')
    end

    it "will create a 'bang' (i.e. update) method if the type is React::Observable" do
      Foo.class_eval do
        param :foo, type: React::Observable
        before_mount do
          params.foo! "ha!"
        end
        def render
          params.foo
        end
      end
      current_state = ""
      observer = React::Observable.new(current_state) { |new_state| current_state = new_state }
      expect(React.render_to_static_markup(React.create_element(Foo, foo: observer))).to eq('<span>ha!</span>')
      expect(current_state).to eq("ha!")
    end
  end
end
end
