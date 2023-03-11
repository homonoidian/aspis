# TODO: independent, dependency-less, logic-only text class?
class SF::Text
  def apply(hi : Hi)
    self.fill_color = hi.color
    self.style = hi.style
    self.font = hi.font
    self.character_size = hi.pt
  end
end

abstract struct Op
end

record Ins < Op, cursor : Cursor, index : Int32, string : String do
  def ord
    cursor.line.ord
  end

  def range
    index...index
  end
end
record Sub < Op, selection : Selection, range : Range(Int32, Int32), string : String do
  def ord
    selection.each_line { |line| return line.ord }

    0
  end
end

# A multi-line capable syntax fragment.
#
# origin  inset
#  +     +
#  v     v
#        line of text\n
#  another line of text\n
#  another line of text\n
#  another line of text\n
#  another line of text\n
#  last line of text
module Theme
  # TODO: dynamic scopes + scope inheritance + fallback scope?

  def initialize(@editor : Cohn)
  end

  abstract def source : Theme::Scope
  abstract def keyword : Theme::Scope

  # todo: fg
  # todo: font
  # todo: font size

  # Returns the background color that should be used for the editor.
  abstract def bg : SF::Color

  # Returns the color that should be used for cursors.
  abstract def cursor_color : SF::Color

  # Returns the color that should be used for beams, e.g. on
  # the left-hand side of block cursors.
  abstract def beam_color : SF::Color

  # Returns the color that should be used for selection rectangles.
  abstract def span_bg : SF::Color
end

module Theme::Scope
  # Returns the font size that should be used for highlights
  # that match this scope.
  abstract def pt : Int # todo: fallback on theme

  # Returns the font that should be used for highlights that
  # match this scope.
  abstract def font : SF::Font # todo: fontmanager::font todo: fallback on theme

  # Returns the color that should be used for highlights that
  # match this scope.
  abstract def color : SF::Color # todo: fallback on theme

  # Returns the text style (regular, italic, bold, etc.) that
  # should be used for highlights that match this scope.
  abstract def style : SF::Text::Style # todo: fontmanager::style
end

module Hi
  def initialize(@theme : Theme)
  end

  abstract def scope : Theme::Scope

  def pt
    scope.pt
  end

  def font
    scope.font
  end

  def color
    scope.color
  end

  def style
    scope.style
  end
end

struct NoHi
  include Hi

  def scope : Theme::Scope
    @theme.source
  end
end

struct HiKeyword
  include Hi

  def scope : Theme::Scope
    @theme.keyword
  end
end

struct SynFrag
  getter hi : Hi

  def initialize(
    @document : Document,
    @range : Range(Int32, Int32),
    @origin : SF::Vector2f,
    @inset : SF::Vector2f,
    @hi = NoHi.new(@document)
  )
    @inset_text = SF::Text.new("", hi.font, hi.pt)
    @inset_text.position = @inset
    @inset_text.apply(hi)

    @rest_text = SF::Text.new("", hi.font, hi.pt)
    @rest_text.position = @origin
    @rest_text.apply(hi)

    @inset_string = ""
    @rest_string = ""

    sync(@range)
  end

  # Returns the index where this fragment begins.
  def begin
    @range.begin
  end

  # Returns the index where this fragment ends.
  def end
    @range.exclusive? ? @range.end - 1 : @range.end
  end

  # Returns the top line in this fragment.
  def top
    @document.index_to_line(self.begin)
  end

  # Returns the bottom line in this fragment.
  def bot
    @document.index_to_line(self.end)
  end

  def string
    @document.slice(self.begin, self.end)
  end

  def includes?(index : Int)
    @range.includes?(index)
  end

  def each_char_with_index
    @range.each do |index|
      yield @document[index], index
    end
  end

  # Updates this fragment's displayed content according to
  # *range*. Returns an updated copy of `SynText`. This copy
  # must be used instead of self after `sync`.
  def sync(@range : Range(Int32, Int32))
    # Inset holds the content of the first line.
    # Rest holds the content of all other lines.

    if @range.in?(top)
      @inset_text.string = @inset_string = @document.slice(self.begin, self.end)
      @rest_text.string = @rest_string = ""
    else
      @inset_text.string = @inset_string = @document.slice(self.begin, top.e)
      @rest_text.string = @rest_string = @document.slice(top.e + 1, self.end)
      # Move rest text below inset text (i.e., on the Y axis).
      @rest_text.position = @origin + SF.vector2f(0, @hi.pt)
    end

    self
  end

  def index_to_extent(index : Int)
    index_to_text_object(index) do |text|
      is_bold = SF::Text::Style.new(text.style.to_i).bold?

      char = @document[index]
      mult = 1

      case char
      when '\n', '\r' # \r case is questionable tbh
        char = ' '
      when '\t'
        char = ' '
        mult = 4
      end

      SF.vector2f(@hi.font.get_glyph(char.ord, text.character_size, is_bold).advance * mult, @hi.pt)
    end
  end

  # Yields text object and document *index* localized to that
  # text object (i.e., indexing into that text object).
  def index_to_text_object(index : Int)
    frag_index = index_to_frag_index(index)

    if frag_index < @inset_string.size
      text_index = frag_index
      text_object = @inset_text
    else
      text_index = frag_index - @inset_string.size
      text_object = @rest_text
    end

    yield text_object, text_index
  end

  # Localizes document *index* to this fragment.
  def index_to_frag_index(index : Int)
    index - self.begin
  end

  def index_to_coords(index : Int)
    if index < self.begin
      @inset_text.position
    elsif index > self.end
      index_to_coords(self.end) - index_to_coords(bot.b)
    else
      index_to_text_object(index) do |text, frag_index|
        text.find_character_pos(frag_index)
      end
    end
  end

  def present(window)
    window.draw(@inset_text)
    window.draw(@rest_text)
  end
end

struct SynText
  def initialize(
    @document : Document,
    @range : Range(Int32, Int32),
    @origin : SF::Vector2f
  )
    @frags = [] of SynFrag

    sync(range)
  end

  # Ensures *range* is a subrange of this syntax text's range:
  # raises `ArgumentError` otherwise.
  private def must_be_subrange(range : Range)
    unless subrange?(range)
      raise ArgumentError.new("argument out of subrange bounds: #{range}")
    end
  end

  # Returns whether *range* is a subrange of this syntax
  # text's range.
  def subrange?(range : Range(Int32, Int32))
    range.begin.in?(@range) && range.end.in?(@range)
  end

  def frag(range : Range(Int32, Int32), origin : SF::Vector2f, inset : SF::Vector2f, hi = NoHi.new(@document.theme))
    must_be_subrange(range)

    SynFrag.new(@document, range, origin, inset, hi)
  end

  def begin
    @range.begin
  end

  def end
    @range.exclusive? ? @range.end - 1 : @range.end
  end

  # Finds and returns the `SynFrag` which contains the given
  # document *index*.
  def index_to_frag(index : Int)
    if frag = @frags.find &.includes?(index)
      return frag
    end

    # Note: frags are guaranteed to have at least one member.
    index < self.begin ? @frags.first : @frags.last
  end

  def index_to_extent(index : Int)
    frag = index_to_frag(index)
    frag.index_to_extent(index)
  end

  def index_to_coords(index : Int)
    frag = index_to_frag(index)
    frag.index_to_coords(index)
  end

  private def corner
    corner = @origin

    @frags.each do |frag|
      frag.each_char_with_index do |char, index|
        case char
        when '\n'
          corner = SF.vector2f(@origin.x, corner.y + frag.hi.pt)
        else
          corner += SF.vector2f(frag.index_to_extent(index).x, 0)
        end
      end
    end

    corner
  end

  def sync(@range : Range(Int32, Int32))
    @frags.clear

    start = self.begin
    last = @origin

    top = @document.index_to_line(self.begin)
    bot = @document.index_to_line(self.end)

    # TODO: Document#scan(String s) where s = language id
    #
    # TODO: Document stores {} of Lanaguage Id => Grammar
    #
    # TODO: Grammar is an object which must implement #highlight(string, &)
    @document.scan(/\b(class|def|end|do|if|else|elsif|while|next|break|unless|yield|require|include|extend|case|when|then)\b/) do |match|
      b = match.begin
      e = match.end - 1

      next if b < top.b
      break if e > bot.e

      if start < b
        frag = frag(start..b - 1, origin: SF.vector2f(@origin.x, last.y), inset: last)
        @frags << frag
        last = corner
      end

      frag = frag(b..e, origin: SF.vector2f(@origin.x, last.y), inset: last, hi: HiKeyword.new(@document.theme))
      @frags << frag
      last = corner

      start = e + 1
    end

    if start <= self.end
      frag = frag(start..self.end, origin: SF.vector2f(@origin.x, last.y), inset: last)
      @frags << frag
    end

    # pp @frags

    # If no frags were created before the end of sync(), shove
    # everything in the sync-d range into one fragment and push
    # it instead.
    if @frags.empty?
      @frags << frag(range, @origin, @origin)
    end

    self
  end

  def present(window)
    @frags.each &.present(window)
  end
end

class Document
  property! editor : Cohn # TODO: smellish smell

  getter font, pt # TODO: these smell cheesy

  getter theme

  def initialize(@buf : TextBuffer, @theme : Theme) # TODO: font is document view
    @ops = [] of Op
    @text = uninitialized SynText # FIXME
    @text = SynText.new(self, range: top.b..bot.e, origin: SF.vector2f(0, 0))
  end

  delegate :word_begin_at, :word_end_at, :word_bounds_at, :size, :slice, :[], to: @buf

  def sync
    @text = @text.sync(top.b..bot.e)
  end

  def theme=(@theme)
    sync
  end

  def scroll(delta : Int)
  end

  def scroll_to_view(index : Int)
  end

  def begin
    0
  end

  def end
    size - 1
  end

  def top
    ord_to_line(0)
  end

  def bot
    ord_to_line(@buf.lines - 1)
  end

  def string
    slice(top.b, bot.e)
  end

  def clamp(index : Int)
    index.clamp(self.begin..self.end)
  end

  def ord_to_line(ord : Int)
    @buf.line(ord)
  end

  def ord_to_line?(ord : Int)
    @buf.line?(ord)
  end

  def scan(pattern)
    string = slice(self.begin, self.end)
    string.scan(pattern) do |match|
      yield match
    end
  end

  @i2c = {} of Int32 => SF::Vector2f

  def index_to_coords(index : Int) # TODO: move to DocumentView
    @i2c[index] ||= @text.index_to_coords(index)
  end

  def index_to_extent(index : Int) # TODO: move to DocumentView
    @text.index_to_extent(index)
  end

  def index_to_line(index : Int)
    @buf.line_at(index)
  end

  def clamped_index_to_line(index : Int)
    return top if index < top.b
    return bot if index > bot.e
    index_to_line(index)
  end

  def coords_to_line(x : Number, y : Number) # TODO: move to DocumentView
    return top if y <= index_to_coords(top.b).y

    needle = (top.ord..bot.ord).bsearch do |ord|
      line = ord_to_line(ord)
      line_b_y = index_to_coords(line.b).y
      line_e_y = index_to_coords(line.e + 1).y
      line_b_y <= y < line_e_y || line_b_y > y
    end

    needle ? ord_to_line(needle) : bot
  end

  def coords_to_index(x : Number, y : Number) # TODO: move to DocumentView
    line = coords_to_line(x, y)

    return line.b if x <= index_to_coords(line.b).x

    needle = (line.b..line.e).bsearch do |index|
      mid_x = index_to_coords(index).x
      nxt_x = index_to_coords(index + 1).x
      mid_x <= x < nxt_x || x < mid_x
    end

    needle || line.e
  end

  def index_visible?(index : Int)
    index.in?(top.b..bot.e)
  end

  def range_partially_visible?(*, from b, to e)
    vib, vie = top.b, bot.e

    # EITHER b..e is visible OR b..e includes visible
    b <= vib <= e || b <= vie <= e || vib <= b <= vie || vib <= e <= vie
  end

  def line_visible?(line : Line)
    index_visible?(line.b) && index_visible?(line.e)
  end

  def ins(cursor : Cursor, index : Int32, string : String)
    @ops << Ins.new(cursor, index, string)
  end

  def sub(selection : Selection, string : String)
    @ops << Sub.new(selection, selection.min.@index...selection.max.@index, string)
  end

  def apply
    return if @ops.empty?

    tms = Time.measure do
      # TODO: optimize! this is one of the most important & heated up parts of the editor
      imap = {} of Int32 => Int32

      @ops.sort_by! { |op| op.range.begin }
      min_index = @ops[0].range.begin

      s = nil
      bms = Time.measure do
        src = @buf.slice(self.begin, self.end)
        s = String.build do |io|
          size = 0
          start = 0

          @ops.each do |op|
            case op
            when Ins
              # Append what goes before the range
              head = src[start...op.index]
              io << head
              size += head.size
              # Append what we're inserting
              io << op.string
              size += op.string.size
              imap[op.index] = size
              # Move to the end of insertion range
              start = op.index
            when Sub
              # Normalize ops to ranges
              range = op.range
              head = src[start...range.begin]
              io << head
              size += head.size
              imap[range.begin] = size
              unless op.string.empty?
                io << op.string
                size += op.string.size
              end
              imap[range.end] = size
              # Move to the end of replacement range
              start = range.end
            end
          end

          io << src[start...src.size]
        end
      end
      s = s.not_nil!

      puts "Built in #{bms.total_microseconds}μs"

      ums = Time.measure do
        @buf.update(index_to_line(min_index).ord) do |src|
          s
        end
      end

      puts "Updated in #{ums.total_microseconds}μs"

      @i2c.clear

      sync

      @ops.each do |op|
        case op
        when Ins
          op.cursor.seek(imap[op.index], SeekSettings.new(home: op.cursor.home?))
        when Sub
          op.selection.resize do |mini, maxi|
            {imap[op.range.begin], imap[op.range.end]}
          end
        end
      end

      @ops.clear
    end

    puts "Done in #{tms.total_microseconds}μs"
  end

  def inspect(io)
    io << "<document>"
  end

  def present(window)
    @text.present(window)
  end
end

class ScrollableDocument < Document
  @line_offset = 0

  def line_offset=(@line_offset)
    @i2c.clear
  end

  def scroll_to_view(index : Int)
    return if index_visible?(index)

    index_line = index_to_line(index)

    if index < top.b
      self.line_offset = index_line.ord
    elsif index > bot.e
      self.line_offset = Math.max(0, index_line.ord - height)
    end
    sync
    editor.@selections.each do |selection|
      selection.@cursor.move(0)
      selection.@anchor.move(0)
      selection.sync
    end
  end

  def height
    24
  end

  def scroll(delta : Int)
    if delta.negative?
      self.line_offset = Math.max(0, @line_offset + delta)
    else
      self.line_offset = Math.min(@buf.lines - height, @line_offset + delta)
    end
    sync
    editor.@selections.each do |selection|
      selection.@cursor.move(0)
      selection.@anchor.move(0)
      selection.sync
    end
  end

  def top
    ord_to_line(Math.max(0, @line_offset))
  end

  def bot
    ord_to_line(Math.min(@buf.lines - 1, @line_offset + height))
  end
end
