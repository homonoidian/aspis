require "crsfml"
require "./aspis/**"

class Array
  def clear_from(start : Int)
    (@buffer + start).clear(@size - start)
    @size = start
  end
end

# [ ] self-sufficient cursor
#
#
# ----
#
#
#
#
# [ ] handle ins/del 1 000 000s of selections and cursors bearably
#     500 000 cursors do APPLY in: approx 500ms
#     same for selections, really
class Cohn
  include EventTarget

  @editor_rect : Platform::Rect

  def initialize(@window : SF::RenderWindow, content, @platform : Platform, @theme : Theme)
    @buf = TextBuffer.new(content)
    @document = ScrollableDocument.new(platform, @buf, @theme)

    @selections = [] of Selection
    @selections << selection(0, focus: false)

    @visible_selections = [] of Selection

    @editor_rect = platform.rect(
      bg: {@theme.bg.r,
           @theme.bg.g,
           @theme.bg.b,
           @theme.bg.a},
      w: 300,
      h: 300,
    )

    # @editor_rect.size = @platform.send( Vec2f.new(300, 300).to_sf # TODO: platform send: CreateRect(id=UUID, 300x300)
    # @editor_rect.fill_color = @theme.bg

    # @selection = Selection.new(@document, @cursor, @anchor)

    DragHandler.on(self)
    MouseButtonHandler.on(self)
    InputHandler.on(self)
    KeyboardHandler.on(self)

    @document.editor = self

    recompute_visible_selections
  end

  def acquire
    @editor_rect.acquire(@platform)
  end

  def release
    @editor_rect.release(@platform)
  end

  def theme=(@theme : Theme) # TODO: smelly
    new_rect = @editor_rect
    new_rect.bg = {theme.bg.r,
                   @theme.bg.g,
                   @theme.bg.b,
                   @theme.bg.a}
    @editor_rect = new_rect
    @document.theme = @theme
  end

  def selection(cidx : Cursor | Int = 0, aidx : Cursor | Int = cidx, focus = true)
    cursor = BlockCursor.new(@document, cidx)
    anchor = Cursor.new(@document, aidx)
    seln = Selection.new(@document, cursor, anchor)
    if focus
      seln.control do |cursor, _|
        cursor.scroll_to_view
      end
    end
    seln
  end

  # merge overlaps & recompute visible
  def uniq_selections
    @selections.unstable_sort!
    # TODO: consider keeping sorted list of them, it's not that hard
    # TODO: now that i think of it, consider keeping sorted & non-overlapped
    # list, i.e., rule out overlaps at insertion.
    # TODO: although mutations will spoil that
    # TODO: but the sorted list can subscribe to mutations and move
    # stuff using binary search!

    if @selections.size > 1
      stack = [@selections.first] of Selection

      @selections.each(within: 1..) do |hi|
        lo = stack.last
        if lo.overlaps?(hi)
          stack.pop
          hi.min.seek(lo.min)
        end
        stack << hi
      end

      @selections = stack
    end

    @selections.last.control do |cursor, _|
      cursor.scroll_to_view
    end

    recompute_visible_selections
  end

  # just recompute visible, release/acquire rects
  def recompute_visible_selections
    @visible_selections = @selections.select do |sel|
      if sel.visible?
        sel.acquire
        true
      else
        sel.release
        false
      end
    end
  end

  # use everywhere you touch @selections or @document !!!
  def i_touch_selections_or_doc
    result = yield
    uniq_selections
    result
  end

  def clear_selections_from(start : Int)
    @selections.each(within: start.., &.release)
    @selections.clear_from(start)
  end

  def on_drag(event : SF::Event::MouseMoved)
    i_touch_selections_or_doc do
      clear_selections_from(1)
      @selections.each &.split
      @selections.each do |sel|
        sel.control do |cursor, anchor|
          step = ctrl? ? WordDragStep.new(sel) : CharStep.new

          cursor.seek(@document.coords_to_index(event.x, event.y), SeekSettings.new(step: step))
        end
      end
    end
  end

  def on_click(event : SF::Event::MouseButtonPressed)
    i_touch_selections_or_doc do
      if ctrl?
        seln = @selections.last.copy.collapse
        seln.control do |cursor, anchor|
          cursor.seek(@document.coords_to_index(event.x, event.y))
        end
        @selections << seln
      elsif shift?
        clear_selections_from(1)
        @selections.each &.split
        @selections.each do |selection|
          selection.control do |cursor, anchor|
            cursor.seek(@document.coords_to_index(event.x, event.y))
          end
        end
      else
        clear_selections_from(1)
        @selections[0].collapse
        @selections[0].control do |cursor, anchor|
          cursor.seek(@document.coords_to_index(event.x, event.y))
        end
      end
    end
  end

  def on_input(event : SF::Event::TextEntered, chr : Char)
    i_touch_selections_or_doc do
      @selections.each &.ins(chr)
      @document.apply
      @selections.each &.collapse
    end
  end

  def on_scroll(event : SF::Event::MouseWheelScrolled)
    @document.scroll(-event.delta.to_i)
    recompute_visible_selections
  end

  def on_with_ctrl_pressed(event : SF::Event::KeyPressed)
    case event.code
    when .t? # TOGGLE THEME # todo: remove
      if @theme.is_a?(NordTheme)
        self.theme = LightTheme.new(self)
      else
        self.theme = NordTheme.new(self)
      end
    when .a? # Select all
      i_touch_selections_or_doc do
        clear_selections_from(1)
        @selections[0].select_all
      end
    when .l? # Select line
      i_touch_selections_or_doc do
        @selections.each &.select_line
      end
    when .c? # Copy line/copy selection DOES NOT WORK!!
      i_touch_selections_or_doc do
        content = String.build do |io|
          @selections.each do |selection|
            if selection.collapsed?
              # Selection collapsed: copy line.
              io << selection.line.content
              next
            end
            # Selection not collapsed: copy selection.
            selection.each_line_with_bounds do |line, b, e|
              io.puts line.slice(b, e)
            end
          end
        end

        SF::Clipboard.string = content
      end
    when .v? # Paste DOES NOT WORK!!
      i_touch_selections_or_doc do
        s = SF::Clipboard.string
        append = s.ends_with?('\n')

        cols = [] of Int32
        @selections.each do |selection|
          if append && selection.collapsed?
            selection.control do |cursor|
              cols << cursor.column
              cursor.seek_line_end
            end
            selection.insln
            selection.ins(s.chomp)
          end
        end
        @document.apply
        uniq_selections
        index = 0
        @selections.each do |selection|
          if append && selection.collapsed?
            selection.control do |cursor|
              cursor.seek_column(cols[index])
            end
            index += 1
          else
            selection.ins(s)
          end
        end
        @document.apply
        uniq_selections
      end
    when .home? # Insert cursors at start of each empty (shift)/nonempty line
      new_selections =
        @selections.flat_map do |selection|
          linesels = [] of Selection

          selection.each_line do |line|
            next if (shift? && !line.empty?) || (!shift? && line.empty?)
            linesels << selection(line.b, focus: false)
          end

          linesels
        end

      unless new_selections.empty?
        i_touch_selections_or_doc do
          @selections = new_selections
        end
      end
    when .end? # Insert cursors at start of each empty (shift)/nonempty line
      new_selections =
        @selections.flat_map do |selection|
          linesels = [] of Selection

          selection.each_line do |line|
            next if (shift? && !line.empty?) || (!shift? && line.empty?)
            linesels << selection(line.e, focus: false)
          end

          linesels
        end

      unless new_selections.empty?
        i_touch_selections_or_doc do
          @selections = new_selections
        end
      end
    when .left? # Go to the beginning of word
      i_touch_selections_or_doc do
        @selections.each do |selection|
          if shift?
            selection.split
          else
            unless selection.collapsed?
              selection.max.seek(selection.min)
              selection.collapse { }
              next
            end
          end

          selection.control do |cursor, anchor|
            cursor.move(-1, SeekSettings.new(step: WordStep.new))
          end
        end
      end
    when .right? # Go to the end of word
      i_touch_selections_or_doc do
        @selections.each do |selection|
          if shift?
            selection.split
          else
            unless selection.collapsed?
              selection.max.seek(selection.min)
              selection.collapse { }
              next
            end
          end

          selection.control do |cursor, anchor|
            cursor.move(+1, SeekSettings.new(step: WordStep.new))
          end
        end
      end
    when .up? # Copy selection above
      i_touch_selections_or_doc do
        min_seln = @selections.min_by { |it| it.min }
        min_seln.above?.try { |seln| @selections << seln }
      end
    when .down? # Copy selection below
      i_touch_selections_or_doc do
        max_seln = @selections.max_by { |it| it.max }
        max_seln.below?.try { |seln| @selections << seln }
      end
    when .backspace? # Delete word before
      i_touch_selections_or_doc do
        @selections.min_of(&.min).scroll_to_view
        @selections.each do |sel|
          sel.del(-1, SeekSettings.new(step: WordStep.new))
        end
        @document.apply
        @selections.each &.collapse
      end
    when .delete? # Delete word after
      i_touch_selections_or_doc do
        @selections.min_of(&.min).scroll_to_view
        @selections.each do |sel|
          sel.del(+1, SeekSettings.new(step: WordStep.new))
        end
        @document.apply
        @selections.each &.collapse
      end
    else
      return false
    end

    true
  end

  def on_key_pressed(event : SF::Event::KeyPressed)
    case event.code
    when .enter?
      i_touch_selections_or_doc do
        @selections.each &.insln # cannot collide
        @document.apply
        @selections.each &.collapse
      end
    when .backspace?
      i_touch_selections_or_doc do
        @selections.min_of(&.min).scroll_to_view
        @selections.each do |sel|
          sel.del(-1)
        end
        @document.apply
        @selections.each &.collapse
      end
    when .delete?
      i_touch_selections_or_doc do
        @selections.min_of(&.min).scroll_to_view
        @selections.each do |sel|
          sel.del(+1)
        end
        @document.apply
        @selections.each &.collapse
      end
    when .home?
      i_touch_selections_or_doc do
        shift? ? @selections.each &.split : @selections.each &.collapse
        # shift? ? @selection.split : @selection.collapse
        @selections.each do |sel|
          sel.control do |cursor, anchor|
            cursor.seek_line_start
          end
        end
      end
    when .end?
      i_touch_selections_or_doc do
        shift? ? @selections.each &.split : @selections.each &.collapse
        # shift? ? @selection.split : @selection.collapse
        @selections.each do |sel|
          sel.control do |cursor, anchor|
            cursor.seek_line_end
          end
        end
      end
    when .left?
      i_touch_selections_or_doc do
        @selections.each do |selection|
          if shift?
            selection.split
          else
            unless selection.collapsed?
              selection.max.seek(selection.min)
              selection.collapse { }
              next
            end
          end

          selection.control do |cursor, anchor|
            cursor.move(-1)
          end
        end
      end
    when .right?
      i_touch_selections_or_doc do
        @selections.each do |selection|
          if shift?
            selection.split
          else
            unless selection.collapsed?
              selection.min.seek(selection.max)
              selection.collapse { }
              next
            end
          end

          selection.control do |cursor, anchor|
            cursor.move(+1)
          end
        end
      end
    when .up?
      i_touch_selections_or_doc do
        @selections.each do |selection|
          if shift?
            selection.split
          else
            unless selection.collapsed?
              selection.max.seek(selection.min)
              selection.collapse { }
              next
            end
          end

          selection.control do |cursor, anchor|
            cursor.ymove(-1)
          end
        end
      end
    when .down?
      i_touch_selections_or_doc do
        @selections.each do |selection|
          if shift?
            selection.split
          else
            unless selection.collapsed?
              selection.min.seek(selection.max)
              selection.collapse { }
              next
            end
          end

          selection.control do |cursor, anchor|
            cursor.ymove(+1)
          end
        end
      end
    end
  end

  def mainloop
    while @window.open?
      while event = @window.poll_event
        if event.is_a?(SF::Event::Closed)
          @window.close
          break
        end
        @handlers.each &.handle(event)
      end
      @window.clear(SF::Color::White)
      @editor_rect.upload(@platform)
      @document.present(@window)
      @visible_selections.each do |seln|
        seln.present(@window)
      end
      @window.display
    end
  end
end

# TODO: font manager
# TODO: fontmanager::font
# TODO: fontmanager::style
FONT        = SF::Font.from_file("./assets/scientifica.otb")
FONT_ITALIC = SF::Font.from_file("assets/scientificaItalic.otb")

window = SF::RenderWindow.new(SF::VideoMode.new(600, 800), title: "Marple")
window.framerate_limit = 60
content = File.read(ARGV[0]? || "marple.cr")

struct LightTheme
  include Theme

  struct NormalScope
    include Scope

    def pt : Int
      11
    end

    def font : SF::Font
      FONT
    end

    def color : SF::Color
      SF::Color::Black
    end

    def style : SF::Text::Style
      SF::Text::Style::Regular
    end
  end

  struct KeywordScope
    include Scope

    def pt : Int
      11
    end

    def font : SF::Font
      FONT_ITALIC
    end

    def color : SF::Color
      SF::Color::Blue
    end

    def style : SF::Text::Style
      SF::Text::Style::Regular
    end
  end

  def source : Theme::Scope
    NormalScope.new
  end

  def keyword : Theme::Scope
    KeywordScope.new
  end

  def bg : SF::Color
    SF::Color::White
  end

  def cursor_color : SF::Color
    SF::Color.new(0x15, 0x65, 0xC0)
  end

  def beam_color : SF::Color
    SF::Color.new(0x0D, 0x47, 0xA1)
  end

  def span_bg : SF::Color
    SF::Color.new(0, 0, 0xff)
  end
end

struct NordTheme
  include Theme

  struct NormalScope
    include Scope

    def pt : Int
      11
    end

    def font : SF::Font
      FONT
    end

    def color : SF::Color
      SF::Color.new(0xd8, 0xde, 0xe9)
    end

    def style : SF::Text::Style
      SF::Text::Style::Regular
    end
  end

  struct KeywordScope
    include Scope

    def pt : Int
      11
    end

    def font : SF::Font
      FONT_ITALIC
    end

    def color : SF::Color
      SF::Color.new(0xb4, 0x8e, 0xad)
    end

    def style : SF::Text::Style
      SF::Text::Style::Regular
    end
  end

  def source : Theme::Scope
    NormalScope.new
  end

  def keyword : Theme::Scope
    KeywordScope.new
  end

  def bg : SF::Color
    SF::Color.new(0x2e, 0x34, 0x40)
  end

  def cursor_color : SF::Color
    SF::Color.new(0x5e, 0x81, 0xac)
  end

  def beam_color : SF::Color
    SF::Color.new(0x81, 0xa1, 0xc1)
  end

  def span_bg : SF::Color
    SF::Color.new(0xa3, 0xbe, 0x8c)
  end
end

# SF platform backend
sf_stream = Stream(Platform::Message).new
rects = {} of UUID => SF::RectangleShape
released = [] of SF::RectangleShape

warning_threshold = 1000
sf_stream.each do |message|
  if rects.size > warning_threshold
    puts "WARNING: #{rects.size} acquired / #{released.size} released"
    warning_threshold += 1000
  end
  case message.keyword # TODO: use integers/enum
  in .rect_acquire?
    # Check if we have any released rects available.
    id = message.unpack(UUID)
    rects[id] ||= begin
      released.pop? || SF::RectangleShape.new
    end
  in .rect_release?
    id = message.unpack(UUID)
    rects.delete(id).try { |rect| released << rect }
  in .rect_draw?
    rect = message.unpack(Platform::Rect)
    shape = rects[rect.id]? || next
    shape.fill_color = SF::Color.new(rect.bg[0], rect.bg[1], rect.bg[2], rect.bg[3])
    shape.position = SF.vector2f(rect.x, rect.y)
    shape.size = SF.vector2f(rect.w, rect.h)
    window.draw(shape)
  end
end

cohn = uninitialized Cohn # TODO: fixme!
cohn = Cohn.new(window, content, Platform.new(sf_stream), LightTheme.new(cohn))
cohn.acquire
begin
  cohn.mainloop
ensure
  cohn.release
end

at_exit { puts "Rects: #{rects.size}" }
