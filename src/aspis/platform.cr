require "json"
require "uuid"
require "uuid/json"

alias RGBA = {UInt8, UInt8, UInt8, UInt8}

class Platform
  def initialize(@stream : Stream(Message))
  end

  private def entity
    yield UUID.random
  end

  def send(keyword : Keyword, serializable)
    @stream.emit Message.new(keyword, serializable.to_json)
  end

  # todo: generic color
  def rect(bg : RGBA, x : Number = 0, y : Number = 0, w : Number = 0, h : Number = 0)
    entity { |id| Rect.new(id, bg, w, h, x, y) }
  end
end

struct Platform::Message
  getter keyword

  def initialize(@keyword : Keyword, @payload : String)
  end

  def unpack(cls : T.class) : T forall T
    cls.from_json(@payload)
  end
end

enum Platform::Keyword
  RectAcquire
  RectDraw
  RectRelease
end

struct Platform::Rect
  include JSON::Serializable

  getter id : UUID
  property w : Float64
  property h : Float64
  property x : Float64
  property y : Float64
  property bg : RGBA

  def initialize(@id, @bg = {0, 0, 0, 255}, @w = 0, @h = 0, @x = 0, @y = 0)
  end

  # Requests a matching rectangle from the platform backend.
  def acquire(platform : Platform)
    platform.send(Keyword::RectAcquire, @id)

    self
  end

  # Asks platform backend to release (destroy, deallocate)
  # this rectangle, and forget its ID.
  #
  # All subsequent calls to this rectangle will be ignored.
  #
  # If you still have hold of this rectangle, you can acquire
  # it back using `ackquire`.
  def release(platform : Platform)
    platform.send(Keyword::RectRelease, @id)
  end

  # Asks platform backend to draw this rectangle.
  def upload(platform : Platform)
    platform.send(Keyword::RectDraw, self)

    self
  end
end
