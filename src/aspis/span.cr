struct Span
  def initialize(@document : Document)
    @frags = [] of Platform::Rect
  end

  def self.build(document : Document, from : Int, to : Int)
    span = new(document)
    span.build(from, to)
    span
  end

  def color
    color = @document.theme.span_bg

    SF::Color.new(color.r, color.g, color.b, 0x22)
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
    ledge_w = ledge ? self.ledge : 0

    # TODo: beautify
    rect = @document.platform.rect(
      bg: {color.r, color.g, color.b, color.a},
      x: b_pos.x,
      y: b_pos.y,
      w: (e_pos.x - b_pos.x) + ledge_w,
      h: height,
    )

    @frags << rect
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

  def acquire
    @frags.each &.acquire(@document.platform)
  end

  def release
    @frags.each &.release(@document.platform)
  end

  def present(window)
    # TODO: do this on demand somehow?
    @frags.each &.upload(@document.platform)
  end
end
