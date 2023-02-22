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
record Sub < Op, selection : Selection, string : String do
  def ord
    selection.each_line { |line| return line.ord }

    0
  end

  def range
    min, max = selection.minmax
    min.@index...max.@index
  end
end

class Document
  property! editor : Cohn

  def initialize(@buf : TextBuffer, font : SF::Font)
    @text = SF::Text.new(string, font, 11)
    @text.fill_color = SF::Color::Black
    @ops = [] of Op
  end

  delegate :size, to: @buf

  def sync
    @text.string = string
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
    @buf.slice(top.b, bot.e)
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
    @i2c[index] ||= @text.find_character_pos(index)
  end

  def index_to_extent(index : Int) # TODO: move to DocumentView
    font = @text.font.not_nil!
    is_bold = SF::Text::Style.new(@text.style.to_i).bold?
    char = @buf[index]
    if char.in?('\n', '\r') # \r case is questionable tbh
      char = ' '
    end
    SF.vector2f(font.get_glyph(char.ord, @text.character_size, is_bold).advance, 11)
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

  def line_visible?(line : Line)
    index_visible?(line.b) && index_visible?(line.e)
  end

  def ins(cursor : Cursor, index : Int32, string : String)
    @ops << Ins.new(cursor, index, string)
  end

  def sub(selection : Selection, string : String)
    @ops << Sub.new(selection, string)
  end

  def apply
    return if @ops.empty?

    tms = Time.measure do
      imap = {} of Int32 => Int32

      @buf.update(0) do |src|
        min_ord = nil

        s = String.build do |io|
          size = 0
          start = 0

          @ops.each do |op|
            # Normalize ops to ranges
            range = op.range

            min_ord = min_ord ? Math.min(min_ord, op.ord) : op.ord

            case op
            when Ins
              # Append  what goes before the range
              head = src[start...range.begin]
              io << head
              size += head.size
              # Append what we're inserting
              io << op.string
              size += op.string.size
              imap[op.index] = size
              # Move to the end of insertion range
              start = range.end + (range.exclusive? ? 0 : 1)
            when Sub
              head = src[start...range.begin]
              io << head
              size += head.size
              imap[range.begin] = size
              io << op.string
              size += op.string.size
              imap[range.end] = size
              # Move to the end of replacement range
              start = range.end + (range.exclusive? ? 0 : 1)
            end
          end
          io << src[start...src.size]
        end

        s
      end

      @i2c.clear

      sync

      @ops.each do |op|
        case op
        when Ins
          op.cursor.seek(imap[op.index], home: op.cursor.home?)
        when Sub
          op.selection.resize do |mini, maxi|
            {imap[op.range.begin], imap[op.range.end]}
          end
        end
      end

      @ops.clear
    end

    puts "Done in #{tms.total_microseconds}"
  end

  def inspect(io)
    io << "<document>"
  end

  def present(window)
    window.draw(@text)
  end
end

class ScrollableDocument < Document
  @line_offset = 0

  def scroll_to_view(index : Int)
    return if index_visible?(index)

    index_line = index_to_line(index)

    if index < top.b
      @line_offset = index_line.ord
    elsif index > bot.e
      @line_offset = Math.max(0, index_line.ord - height)
    end
    sync
    editor.@selections.each &.sync
  end

  def height
    24
  end

  def index_to_coords(index : Int)
    offset = top.b
    if index < offset
      @text.position
    elsif index > bot.e
      index_to_coords(bot.e) - index_to_coords(bot.b)
    else
      @text.find_character_pos(index - offset)
    end
  end

  def scroll(delta : Int)
    if delta.negative?
      @line_offset = Math.max(0, @line_offset + delta)
    else
      @line_offset = Math.min(@buf.lines - height, @line_offset + delta)
    end
    @text.string = string
    editor.@selections.each &.sync
  end

  def top
    ord_to_line(Math.max(0, @line_offset))
  end

  def bot
    ord_to_line(Math.min(@buf.lines - 1, @line_offset + height))
  end
end
