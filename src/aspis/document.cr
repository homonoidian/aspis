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

# A multi-line syntax fragment.
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
class SynFrag
  def initialize(
    @document : Document,
    @font : SF::Font, @pt : Int32,
    @origin : SF::Vector2f,
    @inset : SF::Vector2f
  )
    @inset_text = SF::Text.new("", @font, @pt)
    @inset_text.position = @inset
    @inset_text.fill_color = SF::Color::Black

    @rest_text = SF::Text.new("", @font, @pt)
    @rest_text.fill_color = SF::Color::Black
    @rest_text.position = @origin

    sync
  end

  def sync
    # Inset holds the content of the first line.
    # Rest holds the content of all other lines.
    @inset_text.string = @document.top.content
    @rest_text.string = @document.slice(@document.top.e + 1, @document.bot.e)

    # Move rest text below inset text (i.e., on the Y axis).
    @rest_text.position = @origin + SF.vector2f(0, @pt)
  end

  def index_to_extent(index : Int)
    index_to_text_object(index) do |text|
      is_bold = SF::Text::Style.new(text.style.to_i).bold?
      char = @document.@buf[index]
      if char.in?('\n', '\r') # \r case is questionable tbh
        char = ' '
      end
      SF.vector2f(@font.get_glyph(char.ord, text.character_size, is_bold).advance, @pt)
    end
  end

  # Yields text object and document *index* localized to that
  # text object (i.e., indexing into that text object).
  def index_to_text_object(index : Int)
    frag_index = index_to_frag_index(index)

    if frag_index < @inset_text.string.size
      text_index = frag_index
      text_object = @inset_text
    else
      text_index = frag_index - @inset_text.string.size
      text_object = @rest_text
    end

    yield text_object, text_index
  end

  # Localizes document *index* to this fragment.
  def index_to_frag_index(index : Int)
    index - @document.top.b
  end

  def index_to_coords(index : Int)
    if index < @document.top.b
      @inset_text.position
    elsif index > @document.bot.e
      index_to_coords(@document.bot.e) - index_to_coords(@document.bot.b)
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

class Document
  property! editor : Cohn

  def initialize(@buf : TextBuffer, font : SF::Font)
    @ops = [] of Op
    @text = uninitialized SynFrag # FIXME
    @text = SynFrag.new(self, font, pt: 11, origin: SF.vector2f(0, 0), inset: SF.vector2f(100, 0))
  end

  delegate :word_begin_at, :word_end_at, :word_bounds_at, :size, :slice, to: @buf

  def sync
    @text.sync
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
      imap = {} of Int32 => Int32

      @ops.sort_by! { |op| op.range.begin }
      min_index = @ops[0].range.begin

      s = nil
      bms = Time.measure do
        src = @buf.@string
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
