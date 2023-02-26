# Clients are allowed to pick which step `Cursor` moves with.
#
# `CursorStep` implementors are objects with (possibly) state
# that advance cursor from one index to another, influenced
# by the state mentioned and/or their own opinion on how the
# motion should happen.
module CursorStep
  # Returns the next cursor index.
  #
  # *prev* and *nxt* are indices belonging to *document*.
  #
  # *prev* index is the previous index (where motion started).
  #
  # *nxt* index is the speculative, character-based next index.
  # It might be out of *document*'s bounds.
  #
  # The latter is usually the index you'd need to change/snap,
  # as a `CursorStep` implementor. The former is given to you
  # so you can e.g. compute delta or determine the direction
  # of the movement.
  #
  # The returned index must be in bounds of the document.
  abstract def advance(document : Document, prev : Int, nxt : Int) : Int
end

# The default kind of cursor step. Advances the cursor to the
# speculative next character, meaning it's character-by-character,
# without-any-state-nor-thought kind of movement.
struct CharStep
  include CursorStep

  def advance(document : Document, prev : Int, nxt : Int) : Int
    document.clamp(nxt)
  end
end

# Advances the cursor to the beginning or to the end of the word
# the speculative next character lands in, depending on whether
# the movement's direction is left or right, respectively.
struct WordStep
  include CursorStep

  def advance(document : Document, prev : Int, nxt : Int) : Int
    b = document.word_begin_at(nxt)

    return b if nxt < prev

    e = document.word_end_at(b)

    # If word is one character long and next lands at its end,
    # return next.
    e == nxt ? nxt : document.word_end_at(nxt)
  end
end

# Advances the cursor to the beginning or to the end of the
# word the speculative next character lands in, depending
# on whether the selection's cursor is before or after its
# anchor, respectively.
#
# This cursor step needs a selection. It is passed during
# initialization.
struct WordDragStep
  include CursorStep

  def initialize(@selection : Selection)
  end

  def advance(document : Document, prev : Int, nxt : Int) : Int
    @selection.control do |cursor, anchor|
      return cursor < anchor ? document.word_begin_at(nxt) : document.word_end_at(nxt)
    end
  end
end
