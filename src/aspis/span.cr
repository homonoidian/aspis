class Span
  def initialize(@document : Document)
    @frags = [] of SF::RectangleShape
  end

  def self.build(document : Document, from : Int, to : Int)
    span = new(document)
    span.build(from, to)
    span
  end

  def color
    SF::Color.new(0, 0, 0xff, 0x22)
  end

  def ledge
    6
  end

  def height
    11
  end

  def inline_frag(line : Line, from b = line.b, to e = line.e, ledge = false)
    return unless @document.line_visible?(line)

    b_pos = @document.index_to_coords(b)
    e_pos = @document.index_to_coords(e)

    shape = SF::RectangleShape.new
    shape.size = SF.vector2f(e_pos.x - b_pos.x, height)
    shape.size += SF.vector2f(self.ledge, 0) if ledge
    shape.position = b_pos
    shape.fill_color = color

    @frags << shape
  end

  def build(begin b : Int, end e : Int)
    top = @document.clamped_index_to_line(b)
    bot = @document.clamped_index_to_line(e)

    # Inline span. Use one fragment.
    if top == bot
      inline_frag top, from: b, to: e
      return
    end

    inline_frag top, from: b, ledge: true
    inline_frag bot, to: e

    # Highlight body from the head body line (below span head)
    # to the bot body line (above span bot).
    #
    # Note that they're the same when three lines are selected.
    return unless btop = @document.ord_to_line?(top.ord + 1)
    return unless bbot = @document.ord_to_line?(bot.ord - 1)

    btop.upto(bbot) { |line| inline_frag line, ledge: true }
  end

  def present(window)
    @frags.each { |frag| window.draw(frag) }
  end
end
