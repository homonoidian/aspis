abstract struct SnapMode
  setter selection : Selection?

  def initialize(@document : Document)
  end
end

struct CharMode < SnapMode
  def snap(prev, nxt)
    nxt
  end
end

struct WordMode < SnapMode
  def snap(prev, nxt)
    return nxt if nxt == prev

    snap_to_beginning = nxt < prev
    @selection.try do |selection|
      next if selection.collapsed?

      selection.control do |cursor, anchor|
        # TODO: breaks C-Shift-Right but fixes mouse & vice versa
        # if removed
        snap_to_beginning = cursor < anchor
      end
    end

    snap_to_beginning ? @document.word_begin_at(nxt) : @document.word_end_at(nxt)
  end
end

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

  property mode : SnapMode

  def initialize(@document : Document, @index : Int32, @home_column : Int32 = 0)
    @mode = CharMode.new(@document)

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

  # Builds and returns a `Span` starting from this cursor up
  # to *other* cursor (based on indices of both). Order matters!
  # This cursor's index must be smaller than that of *other*.
  def span(upto other : Cursor)
    other.span(from: @index)
  end

  # Builds and returns a `Span` starting from *index* up to
  # this cursor. Order matters! This cursor's index must be
  # greater than *index*.
  def span(from index : Int)
    Span.build(@document, from: index, to: @index)
  end

  # Yields `Line`s starting from this cursor's line up to
  # *other*'s line.
  def each_line(upto other : Cursor)
    line.upto(other.line) { |it| yield it }
  end

  # Increments this cursor's index by *delta*.
  #
  # That is, if *delta* is negative, this cursor will move
  # that many characters to the left; if it is positive,
  # this cursor will move that many characters to the right.
  #
  # If *delta* is zero, simply refreshes this cursor's X, Y
  # position in document.
  def move(delta : Int)
    seek(@index + delta)
  end

  # Increments this cursor's line number by *delta*.
  #
  # That is, if *delta* is negative, this cursor will move that
  # many lines up; if it is positive, this cursor will move that
  # many characters down.
  #
  # If unable to move because the cursor is already at the top
  # or bottom line of the document, moves to the first or last
  # character in the document, respectively.
  #
  # Returns self.
  def ymove(delta : Int)
    unless tgt = @document.ord_to_line?(line.ord + delta)
      return seek(delta.negative? ? 0 : @document.size)
    end

    seek(tgt.b + Math.min(@home_column, tgt.size), home: false)
  end

  # Moves *other* cursor to this cursor.
  def attract(other : Cursor, home = true, snap = true)
    return if same?(other)

    other.seek(@index, home, snap)
  end

  # Moves this cursor to *other* cursor.
  def seek(other : Cursor, home = true, snap = true)
    other.attract(self, home, snap)
  end

  # Moves this cursor to *index*. Returns self.
  #
  # *home* determines whether the resulting column will be the
  # home column for this cursor.
  #
  # *snap* forces the active `SnapMode` on index.
  def seek(index : Int, home = true, snap = true)
    from = @index
    index = @document.clamp(index)

    @index = snap ? @mode.snap(@index, index) : index
    @home_column = @index - line.b if home

    if visible?
      rect.size = size
      rect.position = coords
    end

    # Prevent infinite loop down the stream. There ought to be
    # a better way, though, because emitting motion even when
    # no motion occured would be beneficial for e.g. automatic
    # synching.
    unless from == @index
      motions.emit Motion.new(self, from, to: @index)
    end

    self
  end

  # Moves this cursor to the beginning of its line.
  def seek_line_start(home = true)
    seek(line.b, home)
  end

  # Moves this cursor to the end of its line.
  def seek_line_end(home = true)
    seek(line.e, home)
  end

  # Moves this cursor to the given *column*.
  def seek_column(column : Int, home = true)
    seek(line.b + column, home)
  end

  # Inserts *string* before this cursor, then moves this cursor
  # forward by the amount of characters in *string*.
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
  def size
    SF.vector2f(@document.index_to_extent(@index).x, 11)
  end

  def color
    SF::Color.new(0x0D, 0x47, 0xA1, 0x66)
  end
end
