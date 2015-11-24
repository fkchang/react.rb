require 'spec_helper'

if opal?

module Components

  module Controller
    class Component1
      include React::Component
      def render
        self.class.name.to_s
      end
    end
  end

  class Component1
    include React::Component
    def render
      self.class.name.to_s
    end
  end

  class Component2
    include React::Component
    def render
      self.class.name.to_s
    end
  end
end

module Controller
  class SomeOtherClass  # see issue #80
  end
end

class Component1
  include React::Component
  def render
    self.class.name.to_s
  end
end


def render_top_level(controller, component_name)
  React.render_to_static_markup(React.create_element(
    React::TopLevelRailsComponent, {controller: controller, component_name: component_name, render_params: {}}))
end

describe React::TopLevelRailsComponent do

  it 'uses the controller name to lookup a component' do
    expect(render_top_level("Controller", "Component1")).to eq('<span>Components::Controller::Component1</span>')
  end

  it 'can find the name without matching the controller' do
    expect(render_top_level("Controller", "Component2")).to eq('<span>Components::Component2</span>')
  end

  it 'will find the outer most matching component' do
    expect(render_top_level("OtherController", "Component1")).to eq('<span>Component1</span>')
  end

  it 'can find the correct component when the name is fully qualified' do
    expect(render_top_level("Controller", "::Components::Component1")).to eq('<span>Components::Component1</span>')
  end

end
end
