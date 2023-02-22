require "crsfml"
require "./aspis/**"

class Array
  def clear_from(start : Int)
    (@buffer + start).clear(@size - start)
    @size = start
  end
end

# [ ] self-sufficient cursor
# [ ] selection modes: ctrl/dbl-click for word boundary select, CTRL-L/triple click for line select
#     `~!@#$%^&*()-=+[{]}\|;:'",.<>/?
# [ ] document viewport
#
#
#
# ----
#
#
#
#
# [ ] handle ins/del 100 000s of selections and cursors bearably

class Cohn
  def initialize(@window : SF::RenderWindow, content, font)
    @handlers = [] of EventHandler
    @buf = TextBuffer.new(content)
    @document = ScrollableDocument.new(@buf, font)

    @selections = [] of Selection
    @selections << selection(0, first: true)

    # @selection = Selection.new(@document, @cursor, @anchor)

    DragHandler.on(self)
    MouseButtonHandler.on(self)
    InputHandler.on(self)
    KeyboardHandler.on(self)

    @document.editor = self
  end

  def selection(cidx : Cursor | Int = 0, aidx : Cursor | Int = cidx, first = false)
    cursor = BlockCursor.new(@document, cidx)
    anchor = Cursor.new(@document, aidx)
    seln = Selection.new(@document, cursor, anchor)
    unless first
      seln.control do |cursor, _|
        cursor.scroll_to_view
      end
    end
    seln
  end

  def attach(handler : EventHandler)
    @handlers << handler
  end

  def on_drag(event : SF::Event::MouseMoved)
    @selections.clear_from(1)
    @selections.each &.split
    @selections.each do |sel|
      sel.control do |cursor, anchor|
        cursor.seek(@document.coords_to_index(event.x, event.y))
      end
    end
  end

  @shift = false
  @ctrl = false

  def on_click(event : SF::Event::MouseButtonPressed)
    if @ctrl
      seln = @selections.last.copy.collapse
      seln.control do |cursor, anchor|
        cursor.seek(@document.coords_to_index(event.x, event.y))
      end
      @selections << seln
    elsif @shift
      @selections.clear_from(1)
      @selections.each &.split
      @selections.each do |selection|
        selection.control do |cursor, anchor|
          cursor.seek(@document.coords_to_index(event.x, event.y))
        end
      end
    else
      @selections.clear_from(1)
      @selections[0].collapse
      @selections[0].control do |cursor, anchor|
        cursor.seek(@document.coords_to_index(event.x, event.y))
      end
    end
    uniq_selections
  end

  def on_input(event : SF::Event::TextEntered, chr : Char)
    @selections.each &.ins(chr)
    @document.apply
    @selections.each &.collapse
    uniq_selections
  end

  def on_scroll(event : SF::Event::MouseWheelScrolled)
    @document.scroll(-event.delta.to_i)
  end

  def on_key_released(event : SF::Event::KeyReleased)
    case event.code
    when .l_shift?, .r_shift?
      @shift = false
    when .l_control?
      @ctrl = false
    end
  end

  def uniq_selections
    @selections.each do |selection|
      # TODO: merge selections when they overlap instead of rejecting
      @selections.reject! do |other|
        next if selection.same?(other) # do not reject

        selection.overlaps?(other)
      end
    end

    @selections.last.control do |cursor, _|
      cursor.scroll_to_view
    end
  end

  def on_key_pressed(event : SF::Event::KeyPressed)
    case event.code
    when .l_shift?, .r_shift?
      @shift = true
    when .l_control?
      @ctrl = true
    when .a?
      if event.control
        @selections.clear_from(1)
        @selections[0].select_all
      end
    when .l?
      if event.control
        # Select line
        @selections.each &.select_line
      end
    when .c? # doest not work
      if event.control
        # Selection collapsed: copy line
        # Selection nonempty: copy selection
        SF::Clipboard.string = String.build do |io|
          @selections.each do |selection|
            if selection.collapsed?
              io << selection.line.content
            else
              selection.each_line_with_bounds do |line, b, e|
                io.puts line.slice(b, e)
              end
            end
          end
        end
      end
    when .v? # does not work
      if event.control
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
    when .enter?
      @selections.each &.insln # cannot collide
      @document.apply
      @selections.each &.collapse
      uniq_selections
      # @selection.puts("")
    when .backspace?
      @selections.min_of(&.min).scroll_to_view
      @selections.each do |sel|
        sel.del(-1)
      end
      @document.apply
      @selections.each &.collapse
      uniq_selections
      # @selection.del(-1)
    when .delete?
      @selections.min_of(&.min).scroll_to_view
      @selections.each do |sel|
        sel.del(1)
      end
      @document.apply
      @selections.each &.collapse
      uniq_selections
      # @selection.del
    when .home?
      if event.control
        # For each selection, insert cursors at start of each line
        @selections =
          @selections.flat_map do |selection|
            linesels = [] of Selection

            selection.each_line do |line|
              linesels << selection(line.b)
            end

            linesels
          end
        uniq_selections
        return
      end
      event.shift ? @selections.each &.split : @selections.each &.collapse
      # event.shift ? @selection.split : @selection.collapse
      @selections.each do |sel|
        sel.control do |cursor, anchor|
          cursor.seek_line_start
        end
      end
      uniq_selections
    when .end?
      if event.control
        # For each selection, insert cursors at start of each line
        @selections =
          @selections.flat_map do |selection|
            linesels = [] of Selection

            selection.each_line do |line|
              next if (event.shift && !line.empty?) || (!event.shift && line.empty?)
              linesels << selection(line.e)
            end

            linesels
          end
        uniq_selections
        return
      end
      event.shift ? @selections.each &.split : @selections.each &.collapse
      # event.shift ? @selection.split : @selection.collapse
      @selections.each do |sel|
        sel.control do |cursor, anchor|
          cursor.seek_line_end
        end
      end
      uniq_selections
    when .left?
      @selections.each do |selection|
        if event.shift
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

      uniq_selections
    when .right?
      @selections.each do |selection|
        if event.shift
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
      uniq_selections
    when .up?
      if event.control
        min_seln = @selections.min_by { |it| it.min }
        min_seln.above?.try { |seln| @selections << seln }
      else
        @selections.each do |selection|
          if event.shift
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
      uniq_selections
    when .down?
      if event.control
        max_seln = @selections.max_by { |it| it.max }
        max_seln.below?.try { |seln| @selections << seln }
      else
        @selections.each do |selection|
          if event.shift
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
      uniq_selections
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
      @document.present(@window)
      @selections.each do |seln|
        seln.present(@window)
      end
      @window.display
    end
  end
end

window = SF::RenderWindow.new(SF::VideoMode.new(600, 800), title: "Marple")
window.framerate_limit = 60
font = SF::Font.from_file("./assets/scientifica.otb")
content = File.read(ARGV[0]? || "marple.cr")

cohn = Cohn.new(window, content, font)
cohn.mainloop
