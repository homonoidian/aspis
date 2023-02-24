# A selection is a `Span` between a pair of `Cursor`s.
#
# `Selection` subscribes to both cursors, and rebuilds the
# `Span` when either of them moves.
#
# In `collapse`d mode, both cursors have the same position
# and `Span` is empty. `Selection` ensures that: whenever one
# of the cursors moves, `Selection` moves the other one to the
# same position.
#
# In `split` mode, selection lets the cursors loose. Move them
# however you like from the outside or using `control`, and
# `Selection` will do the rest.
class Selection
  @span : Span?
  @gluer : Stream(Cursor)

  # Motions of subordinate cursors.
  @motions = Stream(Cursor::Motion).new

  def initialize(@document : Document, @cursor : Cursor, @anchor : Cursor)
    @cursor.motions.each { sync }
    @anchor.motions.each { sync }

    # When any cursor appears on the gluer stream, we ask both
    # cursors to seek there.
    @gluer = @motions.map(&.cursor)
    @gluer.each do |handle|
      @cursor.seek(handle, home: handle.home?)
      @anchor.seek(handle, home: handle.home?)
    end

    collapse if collapsed?
  end

  # Recalculates the span.
  def sync
    min, max = minmax
    @span = min == max ? nil : min.span(upto: max)
  end

  # Returns a tuple of minimum (leftmost), maximum (rightmost)
  # of this selection's cursors.
  def minmax
    @cursor.minmax(@anchor)
  end

  # Returns the minimum (leftmost) of this selection's cursors.
  def min
    minmax[0]
  end

  # Returns the maximum (rightmost) of this selection's cursors.
  def max
    minmax[1]
  end

  # Returns whether this selection includes *other*'s cursor
  # or *other*'s anchor.
  def overlaps?(other : Selection)
    b1, e1 = minmax
    b2, e2 = other.minmax
    b1 <= b2 <= e1 || b1 <= e2 <= e1
  end

  # Returns whether this selection is multiline.
  def multiline?
    @cursor.line != @anchor.line
  end

  # By default, anchor and cursor of a selection are "glued"
  # together. This method disables that. Returns self.
  def split
    # Disconnect cursors from the motion stream, that gluer
    # is subscribed to.
    @cursor.motions.forget(@motions)
    @anchor.motions.forget(@motions)

    self
  end

  # "Glues" together anchor and cursor of this selection. Usually
  # called sometime after `split`.
  #
  # Yields cursor to the block after collapsing so you can move it
  # (e.g. in situations when the cursor is in an invalid state).
  #
  # Returns self.
  def collapse(&)
    # Connect both cursors to the motions stream, that gluer
    # is subscribed to.
    @cursor.motions.notifies(@motions)
    @anchor.motions.notifies(@motions)
    yield @cursor

    self
  end

  # "Glues" together anchor and cursor of this selection. Usually
  # called sometime after `split`.
  #
  # Use `collapse(&)` if the cursor is in an invalid state (e.g. you
  # need to move it to the beginning *after* clearing the source).
  # This method will raise if you try to do that.
  def collapse
    collapse { @gluer.emit(@cursor) }
  end

  # Returns whether this selection is collapsed (see `collapse`).
  def collapsed?
    @cursor == @anchor
  end

  # Resizes this selection: yields minimum (start), maximum (end)
  # indices to the block, and expects the block to return a tuple
  # of new start, end indices. Moves the anchor to the start index,
  # and cursor to the end index.
  #
  # Returns self.
  def resize
    b, e = yield minmax.map(&.@index)
    if b == e
      collapse &.seek(b)
    else
      split
      @anchor.seek(b)
      @cursor.seek(e)
    end
    self
  end

  # Returns the line this selection is found in if this selection
  # is inline. If this selection is multiline, raises.
  def line
    raise "no line() for multiline selection" if multiline?

    @cursor.line
  end

  # Yields cursor and anchor to the block so you can e.g. command
  # them to move.
  def control
    yield @cursor, @anchor
  end

  # Returns a copy of this selection, with cursor and anchor
  # copied as well.
  def copy
    Selection.new(@document, @cursor.copy, @anchor.copy)
  end

  # Yields member lines of this selection.
  def each_line
    min.each_line(upto: max) do |line|
      yield line
    end
  end

  def each_line_with_bounds
    unless multiline?
      yield line, min.column, max.column
      return
    end

    yield min.line, min.column, min.line.size - 1

    bmin = @document.ord_to_line?(min.line.ord + 1)
    amax = @document.ord_to_line?(max.line.ord - 1)

    if bmin && amax
      bmin.upto(amax) do |mid|
        yield mid, 0, mid.size - 1
      end
    end

    yield max.line, 0, max.column
  end

  # Selects all content in the document.
  def select_all
    resize { {@document.begin, @document.end} }
  end

  # Selects the current line. If this selection is multiline,
  # extends both ends to the corresponding line boundaries.
  def select_line
    resize { {min.line.b, max.line.e} }
  end

  # Appends *object* after the cursor, or replaces the selected
  # text with *object*.
  #
  # Does not collapse this selection. Instead, this selection
  # is resized to fit the inserted *object*.
  def ins(object : String)
    collapsed? ? @cursor.ins(object) : @document.sub(self, object)
  end

  # :ditto:
  def ins(object)
    ins(object.to_s)
  end

  # Same as `ins`, but follows *object* with a newline, and
  # keeps indentation from this line.
  def insln(object : String = "")
    head = String.build do |io|
      io << object << '\n'
      next if @cursor.at_line_start?
      @cursor.line.each_char do |char|
        break unless char.in?(' ', '\t')
        io << char
      end
    end

    ins(head)
  end

  # :ditto:
  def insln(object)
    insln(object.to_s)
  end

  # Deletes *count* characters starting from cursor if this
  # selection is collapsed. Otherwise, deletes the selected
  # text and ignores *count*.
  def del(count = 0, mode = CharMode.new)
    if collapsed?
      return if count.negative? && @cursor.at_document_start?
      return if count.positive? && @cursor.at_document_end?

      split

      # If count is negative, move anchor back. If it is positive,
      # move cursor forward.
      (count.negative? ? @anchor : @cursor).move(count, mode: mode)
    end

    @document.sub(self, "")
  end

  # If possible, builds and returns a selection object above
  # this selection. Otherwise, returns nil.
  def above?
    return if @cursor.at_first_line? || @anchor.at_first_line?

    ccopy = @cursor.copy
    acopy = @anchor.copy

    Selection.new(@document, ccopy, acopy).tap do
      ccopy.ymove(-1)
      acopy.ymove(-1) unless collapsed?
    end
  end

  # If possible, builds and returns a selection object below
  # this selection. Otherwise, returns nil.
  def below?
    return if @cursor.at_last_line? || @anchor.at_last_line?

    ccopy = @cursor.copy
    acopy = @anchor.copy

    Selection.new(@document, ccopy, acopy).tap do
      ccopy.ymove(+1)
      acopy.ymove(+1) unless collapsed?
    end
  end

  # Displays this selection in *window*.
  def present(window)
    @span.try &.present(window)
    @cursor.present(window)
    @anchor.present(window) unless collapsed?
  end

  # Two selections are equal when their cursors and anchors
  # are equal.
  def_equals_and_hash @cursor, @anchor
end
