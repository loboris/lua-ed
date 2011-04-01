-- inout.lua - file and terminal input/output routines for
-- a version of "ed" in Lua

-- TODO: reimplement internals using Lua model of lines without trailing newline
-- TODO: reimplement using file:lines iterator


-- Import child modules
local buffer = require "buffer" 


local M = {}		-- the module table


-- Screen width/height, also set/used by main_loop.lua
M.window_lines = 24
M.window_columns = 72


-- print text to stdout, applying the conversion flags set in "gflags".
-- gflags['n'] - number the lines
-- gflags['l'] - wrap long lines and escape special characters
-- The Lua character escapes are the same as "ed" escapes, plus \' and \"
-- and with decimal digits instead of octal in the \nnn form
-- "p" does not have a newline at the end of it.
local function put_tty_line(p, gflags)
  local escapes = "\a\b\f\n\r\t\v\\'\""
  local esctab = {	-- map escape chars to their representations
    ['\a']='\\a', ['\b']='\\b', ['\f']='\\f', ['\n']='\\n', ['\r']='\\r',
    ['\t']='\\t', ['\v']='\\v', ['\\']='\\\\', ["'"]="\\'", ['"']='\\"',
  }
  local controls = "([\001-\031\127-\255])"
  local col = 0		-- How many chars have we output on this line?

  if gflags['n'] then
    io.write(string.format("%d\t", buffer.current_addr))
    col = 8
  end
  if not gflags['l'] then
    io.write(p)
  else
    for ch in p:gmatch(".") do
      -- replace a special char with its escape sequence
      ch = ch:gsub("(["..escapes.."])", esctab)
      -- replace other control characters with \nnn (decimal)
      -- Note: \000 is broken in Lua 5.1.4 (fixed in 5.2)
      ch = ch:gsub("([\001-\031\127-\255])",
    	       function(c)
    		 return "\\" .. string.format("%03d", string.byte(c))
	       end)
      -- Unlike ed, we do not overflow the 72nd column on escaped characters
      -- also, when numbering lines we indent all continuation lines to match
      if col + #ch > M.window_columns then
        io.write("\\\n") col = 0
	if gflags['n'] then
	  io.write("\t") col = 8
	end
      end
      io.write(ch)       col = col + #ch
    end
  end
  if gflags['l'] then
    io.write("$")
  end
  io.write("\n")
end

local function display_lines(from, to, gflags)
  local ep = buffer.search_line_node(buffer.inc_addr(to))
  local bp = buffer.search_line_node(from)

  if from == 0 then
    -- I don't believe this can happen.
    error_msg "Invalid address"
    io.write "Impossible error in display_lines\n"
    return
  end

  while bp ~= ep do
    s = bp.line
    buffer.current_addr = from
    from = from + 1
    put_tty_line(s, gflags)
    bp = bp.forw
  end
end
M.display_lines = display_lines

-- read a line of text from stdin and return it or nil on error/EOF
local function get_tty_line()
  -- TODO: io.read() returns the line without its newline character.
  -- TODO: Handle the input char by char, failing if ^C is entered
  local line = io.read()
  if not line then
    return nil
  end
  return line .. "\n"
end
M.get_tty_line = get_tty_line

-- get_extended_line()
-- If *ibufpp contains an escaped newline, get an extended line (one
-- with escaped newlines) from stdin.
-- Return the new buffer (either the same or extended with extra lines)
-- or nil on errors

local function get_extended_line(ibuf, strip_escaped_newlines)

  -- return the parity of escapes at the end of a string
  local function trailing_escape(s)
    local odd_escape = false
    s = s:gsub("\n$", "")
    while s:match("\\$") do
      odd_escape = not odd_escape
      s = s:sub(1,-2)
    end
    return odd_escape
  end

  -- DEBUG: I think the buffer should always be a single line terminated
  -- by a newline
  assert(ibuf:match("^[^\n]*\n$"),
  	 "get_extended_newline was not passed a single line")

  if #ibuf < 2 or not trailing_escape(ibuf) then
    return ibuf
  end
  if strip_escaped_newlines then
    ibuf = ibuf:gsub("\\\n$", "")	-- strip trailing escape and newline
  else
    ibuf = ibuf:gsub("\\\n$", "\n")	-- strip trailing escape
  end

  -- TODO: reimplement with concat of table of strings,
  -- checking each *new* line for an escaped newline
  while true do
    local s = get_tty_line()
    if not s then return nil end
    -- TODO Handle lack of terminating newline
    ibuf = ibuf .. s
    if #ibuf < 2 or not trailing_escape(ibuf) then
      break
    end
    if strip_escaped_newlines then
      ibuf = ibuf:gsub("\\\n$", "")	-- strip trailing escape and newline
    else
      ibuf = ibuf:gsub("\\\n$", "\n")	-- strip trailing escape
    end
  end
  return ibuf
end
M.get_extended_line = get_extended_line

-- read a stream into the editor buffer after line "addr";
-- return the number of characters read.
local function read_stream(fp, addr)

  -- read_stream()
  -- Read a line of text from a file object.
  -- Return the line terminated by a newline
  -- "" at EOF or nil on error
  local function read_stream_line(fp)
    local line = fp:read()
    if not line then
      return ""
    end
    return line .. "\n"
  end

  local lp = buffer.search_line_node(addr)
  local size = 0
  --UNDO
  buffer.current_addr = addr
  while true do
    local s = read_stream_line(fp)
    if #s == 0 then
      break
    end
    size = size + #s
    buffer.put_sbuf_line(s, buffer.current_addr)
    lp = lp.forw
    -- UNDO
  end
  return size
end

-- read a named file/pipe into the buffer
-- return number of lines read or nil on error
local function read_file(filename, addr)
  local fp,err
  if filename:match("^!") then
    error_msg "Shell escapes are not implemented"
    return nil
  else
    fp,err = io.open(filename)
  end
  if not fp then
    error_msg(err)
    return nil
  end
  local size = read_stream(fp, addr)
  if not size then
    return nil
  end
  fp:close()
  io.write(string.format("%d\n", size))
  return buffer.current_addr - addr
end
M.read_file = read_file

-- write a range of lines to a stream
-- Return number of byte written or nil on error

local function write_stream(fp, from, to)
  local lp = buffer.search_line_node(from)
  local size = 0

  while from ~= 0 and from <= to do
    local p = lp.line .. "\n"
    size = size + #p
    if not fp:write(p) then
      error_msg "Cannot write file"
      return nil
    end
    from = from + 1
    lp = lp.forw
  end
  return size
end

-- write a range of lines to a named file/pipe
-- return line count or nil on error
local function write_file(filename, mode, from, to)
  local fp, size

  if filename:match("^!") then
    error_msg "Shell escapes not implemented"
    return nil
  else
    -- TODO strip_escapes(filename)
    fp = io.open(filename, mode)
  end
  if not fp then
    error_msg "Cannot open output file"
    return nil
  end
  size = write_stream(fp, from, to)
  if not size then return nil end
  if not fp:close() then
    error_msg "Error closing output file"
  end
  io.write(string.format("%d\n", size))
  return (from ~= 0 and from <= to) and (to - from + 1) or 0
end
M.write_file = write_file

return M
