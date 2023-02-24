module EventTarget
  # Returns whether the control key is pressed.
  property? ctrl = false

  # Returns whether the shift key is pressed.
  property? shift = false

  @handlers = [] of EventHandler

  # Attaches *handler* to this event target.
  def attach(handler : EventHandler)
    @handlers << handler
  end
end

abstract class EventHandler
  def initialize(@target : EventTarget)
  end

  # Attaches an instance of this event handler to *target*.
  def self.on(target)
    target.attach new(target)
  end

  # Helper method to set a "wall" around a macro so
  # we can 'next' out.
  private def block
    yield
  end

  # Invokes a method with the given *name* (a symbol literal) on
  # target, passing it positional *args* and keyword arguments
  # *kwargs*. Noop if the method does not exist.
  #
  # Use with caution: use this **only** inside instance-side
  # methods of a handler subclass!
  macro send?(name, *args, **kwargs)
    block do
      {% unless name.is_a?(SymbolLiteral) %}
        {% raise "EventHandler#send(...): argument 'name' must be a symbol literal" %}
      {% end %}

      %target = @target

      # Exit out of "block do ... end" if there is no such
      # method in target.
      next unless %target.responds_to?({{name}})

      %target.{{name.id}}({{*args}}, {{**kwargs}})
    end
  end

  # Sets *name* to *value* in event target.
  macro set(name, value)
    @target.{{name.id}} = {{value}}
  end

  # Handles or ignores *event*.
  def handle(event)
  end
end

class DragHandler < EventHandler
  @had_mouse_pressed = false

  def handle(event : SF::Event::MouseButtonReleased)
    @had_mouse_pressed = false
  end

  def handle(event : SF::Event::MouseButtonPressed)
    @had_mouse_pressed = true
  end

  def handle(event : SF::Event::MouseMoved)
    return unless @had_mouse_pressed

    send?(:on_drag, event)
  end
end

class MouseButtonHandler < EventHandler
  def handle(event : SF::Event::MouseButtonPressed)
    send?(:on_click, event)
  end

  def handle(event : SF::Event::MouseWheelScrolled)
    send?(:on_scroll, event)
  end
end

class InputHandler < EventHandler
  def handle(event : SF::Event::TextEntered)
    chr = event.unicode.chr

    return unless chr.printable? || chr == '\t'

    send?(:on_input, event, chr)
  end
end

class KeyboardHandler < EventHandler
  def handle(event : SF::Event::KeyReleased)
    if event.code.l_control? || event.code.r_control?
      set(:ctrl, false)
    end

    if event.code.l_shift? || event.code.r_shift?
      set(:shift, false)
    end

    unless event.control && send?(:on_with_ctrl_released, event)
      send?(:on_key_released, event)
    end
  end

  def handle(event : SF::Event::KeyPressed)
    if event.code.l_control? || event.code.r_control? || event.control
      set(:ctrl, true)
    end

    if event.code.l_shift? || event.code.r_shift? || event.shift
      set(:shift, true)
    end

    unless event.control && send?(:on_with_ctrl_pressed, event)
      send?(:on_key_pressed, event)
    end
  end
end
