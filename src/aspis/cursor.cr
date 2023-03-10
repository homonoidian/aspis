# Describes *how* a cursor should seek. Belongs primarily to
# `Cursor#seek`, but may be required or allowed by other,
# descendant methods.
#
# `home` describes whether the seek-d column should persist
# as the cursor's home column.
#
# `step` specifies which `CursorStep` should be used to seek
# the desired index.
record SeekSettings, home = true, step : CursorStep = CharStep.new

# Represents a cursor in the editor. Appearance is managed
# here too.
#
# Cursor is not yet self-sufficient. You must use `Selection`
# to have complete editing capabilities.
class Cursor
  include Comparable(Cursor)

  # Motion objects store the `cursor` that moved, the index
  # `from` where it moved, and the index `to` which it moved.
  record Motion, cursor : Cursor, from : Int32, to : Int32

  # Returns a stream which yields `Motion` objects whenever
  # this cursor moves.
  getter motions : Stream(Motion) { Stream(Motion).new }

  # Returns the rectangle shape used by this cursor.
  private getter rect : SF::RectangleShape do
    rect = SF::RectangleShape.new
    rect.fill_color = color
    rect
  end

  def initialize(@document : Document, @index : Int32, @home_column : Int32 = 0)
    move(0)
  end

  # Compares this cursor and *other* cursor by indices.
  def <=>(other : Cursor)
    @index <=> other.@index
  end

  # Returns a tuple with this and *other* cursor sorted in ascending
  # order (minimum to maximum, aka leftmost to rightmost).
  def minmax(other : Cursor)
    self <= other ? {self, other} : {other, self}
  end

  # Returns the point coordinates of this cursor in the document.
  def coords
    @document.index_to_coords(@index)
  end

  # Returns the `Line` of this cursor.
  def line
    @document.index_to_line(@index)
  end

  # Returns the column (offset from line start) of this cursor.
  # Columns are counted starting from zero!
  def column
    @index - line.b
  end

  # Returns whether this cursor's column is its preferred
  # *home column*.
  def home?
    @home_column == column
  end

  # Returns whether this cursor is located at the beginning of
  # its line.
  def at_line_start?
    @index == line.b
  end

  # Returns whether this cursor is located at the end of its line.
  def at_line_end?
    @index == line.e
  end

  # Returns whether this cursor is located before the first
  # character in the document.
  def at_document_start?
    @index == @document.begin
  end

  # Returns whether this cursor is located after the last
  # character in the document.
  def at_document_end?
    @index == @document.end
  end

  # Returns whether this cursor is located at the first line
  # in the document.
  def at_first_line?
    line.first_line?
  end

  # Returns whether this cursor is located at the last line
  # in the document.
  def at_last_line?
    line.last_line?
  end

  # Returns whether this cursor is visible in the document.
  def visible?
    @document.index_visible?(@index)
  end

  # Returns whether the range starting from this cursor, and
  # up to *other* cursor, is partially or completely visible.
  def partially_visible?(*, upto other : Cursor)
    other.partially_visible?(from: @index)
  end

  # Returns whether the range starting from the given *start*
  # index, and up to this cursor, is partially or completely
  # visible.
  def partially_visible?(*, from start : Int)
    @document.range_partially_visible?(from: start, to: @index)
  end

  # Builds and returns a `Span` starting from this cursor up
  # to *other* cursor (based on indices of both). Order matters!
  # This cursor's index must be smaller than that of *other*.
  def span(*, upto other : Cursor)
    other.span(from: @index)
  end

  # Builds and returns a `Span` starting from *start* up to
  # this cursor. Order matters! This cursor's index must be
  # greater than *start*.
  def span(*, from start : Int)
    Span.build(@document, from: start, to: @index)
  end

  # Yields `Line`s starting from this cursor's line up to
  # *other*'s line.
  def each_line(upto other : Cursor)
    line.upto(other.line) { |it| yield it }
  end

  # Increments this cursor's index by *delta*.
  #
  # That is, if *delta* is negative, this cursor will move that
  # many characters to the left; if it is positive, this cursor
  # will move that many characters to the right.
  #
  # If *delta* is zero, simply refreshes this cursor's X, Y
  # position in document.
  #
  # See `seek` to learn what *settings* are.
  #
  # Returns self.
  def move(delta : Int, settings = SeekSettings.new)
    seek(@index + delta, settings)
  end

  # Increments this cursor's line number by *delta*.
  #
  # That is, if *delta* is negative, this cursor will move that
  # many lines up; if it is positive, this cursor will move that
  # many lines down.
  #
  # If unable to move because the cursor is already at the top
  # or bottom line of the document, moves to the first or last
  # character in the document, respectively.
  #
  # See `seek` to learn what *settings* are.
  #
  # Returns self.
  def ymove(delta : Int, settings = SeekSettings.new(home: false))
    unless tgt = @document.ord_to_line?(line.ord + delta)
      return seek(delta.negative? ? 0 : @document.size)
    end

    seek(tgt.b + Math.min(@home_column, tgt.size), settings)
  end

  # Moves ("teleports") *other* cursor to this cursor.
  #
  # See `seek` to learn what *settings* are.
  def attract(other : Cursor, settings = SeekSettings.new)
    return if same?(other)

    other.seek(@index, settings)
  end

  # Moves ("teleports") this cursor to *other* cursor.
  #
  # See `seek` to learn what *settings* are.
  def seek(other : Cursor, settings = SeekSettings.new)
    other.attract(self, settings)
  end

  # Moves this cursor to *index*.
  #
  # *settings* specify how this method should seek *index*.
  # See `SeekSettings` for the available settings.
  #
  # Returns self.
  def seek(index : Int, settings = SeekSettings.new)
    from = @index
    index = @document.clamp(index)

    @index = settings.step.advance(@document, @index, index)
    @home_column = @index - line.b if settings.home

    if visible?
      rect.size = size
      rect.position = coords
    end

    # Prevent infinite loop down the stream. There ought to be
    # a better way, though, because emitting motion even when
    # no motion occured could be beneficial.
    unless from == @index
      motions.emit Motion.new(self, from, to: @index)
    end

    self
  end

  # Moves this cursor to the beginning of its line.
  #
  # See `seek` to learn what *settings* are.
  def seek_line_start(settings = SeekSettings.new)
    seek(line.b, settings)
  end

  # Moves this cursor to the end of its line.
  #
  # See `seek` to learn what *settings* are.
  def seek_line_end(settings = SeekSettings.new)
    seek(line.e, settings)
  end

  # Moves this cursor to the given *column*.
  #
  # See `seek` to learn what *settings* are.
  def seek_column(column : Int, settings = SeekSettings.new)
    seek(line.b + column, settings)
  end

  # Inserts *string* before this cursor.
  def ins(string : String)
    @document.ins(self, @index, string)
  end

  # Asks the document to scroll this cursor to view.
  def scroll_to_view
    @document.scroll_to_view(@index)
  end

  # Returns a shallow copy of this cursor.
  def copy
    self.class.new(@document, @index, @home_column)
  end

  # Returns a float vector that is the width, height of this
  # cursor's rectangle.
  def size
    SF.vector2f(1, 11)
  end

  # Returns the color of this cursor.
  def color
    SF::Color.new(0x15, 0x65, 0xC0, 0xcc)
  end

  # Presents this cursor on *window*.
  def present(window)
    return unless visible?

    window.draw(rect)
  end

  # Two cursors are equal when their indices are equal.
  def_equals_and_hash @index
end

# Block appearance for `Cursor`. Assumes the width of the
# character under the cursor.
class BlockCursor < Cursor
  def initialize(*args, **kwargs)
    super(*args, **kwargs)

    @beam = SF::RectangleShape.new(size: SF.vector2f(1, 11)) # TODO: cursor view?
    @beam.fill_color = SF::Color.new(0x0D, 0x47, 0xA1)
  end

  def size
    SF.vector2f(@document.index_to_extent(@index).x, 11)
  end

  def color
    SF::Color.new(0x0D, 0x47, 0xA1, 0x66)
  end

  def present(window)
    return unless visible?

    super

    @beam.position = rect.position

    window.draw(@beam)
  end
end
