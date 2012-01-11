-- ed.regex.lua - the pattern-matching and substituting part of
-- a version of "ed" in Lua.  Uses Lua patterns and substitutions, not regex.

local M = {}		-- the module table


local buffer = require "buffer"
local inout = require "inout"		-- only for get_tty_line :-(


-- Persistent local data
local global_pat = nil	-- the last pattern we matched
local stbuf = nil	-- substitution template buffer


-- Is there a pattern stored from a previous search/substitution?
local function prev_pattern()
  return global_pat and true or false
end
M.prev_pattern = prev_pattern

-- Escape special characters in a string that will be used as a Lua
-- character class. This means an initial ^, a ], a - and % itself.
-- Actually, the ^ is only special as the first character, and - when it
-- is between two characters within the [] pair.
-- However we go for simplicity and escape them all always.
local function lua_cc_escape(buf)
  return buf:gsub("[%^%]%-%%]", "%%%0")
end

-- copy a pattern string from the command buffer and return a copy of it.
-- Return values: the pattern string (or nil) and the new value of ibuf.
-- On entry, ibuf is at the start of the pattern, after the first delimiter.
-- On return, the first char in ibuf is the delimiter (or newline if none)
-- For simplicity, the delimiter character cannot occur in the pattern.

local function extract_pattern(ibuf, delimiter)
  local delim_cc = lua_cc_escape(delimiter)
  local buf = ""
  
  while not ibuf:match("^["..delim_cc.."\n]") do
    --TODO parse character classes
    buf = buf .. ibuf:sub(1,1)
    ibuf = ibuf:sub(2)
  end
  return buf,ibuf
end

-- Return the first pattern in the command line and the remainder of the line.
-- The pattern may be nil if the pattern does not parse.
-- On entry, the first character of ibuf is the delimiter
-- On return, the first character of ibuf is the closing delimiter
local get_compiled_pattern	-- forward declaration
do
  -- Persistent variables
  local exp = nil

  function get_compiled_pattern(ibuf)
    local delimiter = ibuf:sub(1,1)
    local delim_cc = lua_cc_escape(delimiter)

    if delimiter == " " then
      error_msg "Invalid pattern delimiter"
      return nil
    end
    if delimiter == '\n' or ibuf:sub(2,2):match("[\n"..delim_cc.."]") then
      if delimiter ~= '\n' then ibuf = ibuf:sub(2) end
      if not exp then error_msg "No previous pattern" end
      return exp,ibuf
    end
    ibuf = ibuf:sub(2)
    exp,ibuf = extract_pattern(ibuf, delimiter)
    return exp,ibuf	-- exp may be nil on failure
  end
end

-- Add lines matching (or not matching) a pattern to the global-active list.
-- Returns the command buffer starting at the closing delimiter on success
-- or nil on failure.
local function build_active_list(ibuf, first_addr, second_addr, match)
  local delimiter = ibuf:sub(1,1)
  local pat, lp

  if delimiter:match("[ \n]") then
    error_msg "Invalid pattern delimiter"
    return nil
  end
  pat,ibuf = get_compiled_pattern(ibuf)
  if not pat then return nil end
  if ibuf:sub(1,1) == delimiter then
    ibuf = ibuf:sub(2)
  end
  buffer.clear_active_list()
  lp = buffer.search_line_node(first_addr)
  for addr = first_addr,second_addr do
    local s = lp.line
    if not s then return nil end
    if (match and s:find(pat)) or (not match and not s:find(pat)) then
      buffer.set_active_node(lp)
    end
    lp = lp.forw
  end
  return ibuf
end
M.build_active_list = build_active_list

-- return a copy of the substitution template in the command buffer
-- Dumps the substitution template in stbuf and returns the remainder of the
-- command line starting at the closing delimiter (or nil on failure)
local function extract_subst_template(ibuf, isglobal)
  local delimiter = ibuf:sub(1,1)
  ibuf = ibuf:sub(2)
  if ibuf:sub(1,1) == '%' and ibuf:sub(2,2) == delimiter then
    ibuf = ibuf:sub(2)
    if not stbuf then
      error_msg "No previous substitution"
      return nil
    end
    -- template is already in stbuf
    return ibuf
  end
  stbuf = ""
  while ibuf:sub(1,1) ~= delimiter do
    if ibuf == "\n" then break end
    if ibuf:match("^\\\n") then
      stbuf = stbuf..'\n'
      if not isglobal then
        ibuf = inout.get_tty_line()
	if not ibuf then
	  errmsg "Unexpected EOF"
          return nil
        end
      end
    else
      stbuf = stbuf..ibuf:sub(1,1)
      ibuf = ibuf:sub(2)
    end
  end
  return ibuf
end

-- extract subtitution tail from the command buffer
-- Returns the flags (or nil on failure), the number of substitutions to make
-- and the rest of the command buffer (probably just newline)
local
function extract_subst_tail(ibuf, isglobal)
  local delimiter = ibuf:sub(1,1)
  local gflags, snum = {}, nil

  if delimiter == '\n' then
    stbuf = ""
    return {p=true},snum,ibuf
  end

  ibuf = extract_subst_template(ibuf, isglobal)
  if not ibuf then return nil end

  if ibuf:match("^\n") then
    return {p=true},snum,ibuf
  end

  if ibuf:sub(1,1) == delimiter then
    ibuf = ibuf:sub(2)
  end

  if ibuf:match("^[1-9]") then
    snum,ibuf = parse_int(ibuf)
  end

  if ibuf:match("^g") then
    ibuf = ibuf:sub(2)
    gflags = { g=true }
  end

  return gflags,snum,ibuf
end
M.extract_subst_tail = extract_subst_tail

-- return the address of the next line matching a pattern in a given
-- direction. wrap around begin/end of editor buffer if necessary.
-- "forward" is boolean, saying whether we should search forwards or
-- backward.
-- Returns a line number (or nil on failure) and the rest of ibuf.
local
function next_matching_node_addr(ibuf, forward)
  local pat
  pat,ibuf = get_compiled_pattern(ibuf)
  if not pat then return nil end
  local addr = buffer.current_addr
  repeat
    addr = forward and buffer.inc_addr(addr) or buffer.dec_addr(addr)
    if addr ~= 0 then
      local lp = buffer.search_line_node(addr)
      local s = lp.line
      local ok

      -- Since the user supplies the pattern we must match,
      -- we catch syntax errors in the pattern and report the error message.
      ok,s = pcall(s.match, s, pat)
      if not ok then
        error_msg(s)
        return nil
      end
      if s then return addr,ibuf end
    end
  until addr == buffer.current_addr
  error_msg "No match"
  return nil
end
M.next_matching_node_addr = next_matching_node_addr

-- Parse a pattern from ibuf and store it in global_pat.
-- Returns the rest of ibuf, or nil on failure.
-- "new_compiled_pattern" is the name of the corresponding GNU ed function;
-- here we use Lua patterns so the "compiled" form is the same as the pattern.
local
function new_compiled_pattern(ibuf)
  local tpat
  tpat,ibuf = get_compiled_pattern(ibuf)
  if tpat then
    global_pat = tpat
    return ibuf
  end
  return nil
end
M.new_compiled_pattern = new_compiled_pattern

-- replace text matches by the pattern in global_pat according to the
-- substitution template in stbuf.
-- Return the resulting text and the number of substitutions made
-- or nil on errors such as failure to parse the patterns.
-- if we return 0 as the number of substitutions, the line was not changed.

local function replace_matching_text(lp, gflags, snum)
  local txt = lp.line
  local ok

  -- With no explicit number and no 'g', just replace the first occurrence
  if not snum and not gflags['g'] then snum = 1 end
  -- 'g' overrides snum
  if gflags['g'] then snum = nil end

  -- Since the user supplies the pattern we must match,
  -- we catch syntax errors in the pattern and report the error message.
  -- The unprotected equivalent is: return txt:gsub(global_pat, stbuf, snum).
  ok, txt, snum = pcall(txt.gsub, txt, global_pat, stbuf, snum)
  -- snum is now the number of substitutions that were made
  if not ok then
    error_msg(txt)
    return nil
  end
  return txt,snum
end

-- for each line in a range, change text matching a pattern according to
-- a substitution template; return true if successful, false on errors
-- Not finding the searched-for text in any line is an error.

local
function search_and_replace(first_addr, second_addr, gflags, snum, isglobal)
  local lc
  local match_found = false
  local up = nil	-- for undo

  buffer.current_addr = first_addr - 1
  for lc = 0, second_addr - first_addr do
    local lp = buffer.search_line_node(buffer.inc_current_addr())
    local txt,nsub = replace_matching_text(lp, gflags, snum)
    if not txt then return nil end
    if nsub > 0 then
      buffer.delete_lines(buffer.current_addr, buffer.current_addr, isglobal)
      txt = txt .. "\n"  -- put_sbuf_line needs a trailing newline so supply it
      repeat
        txt = buffer.put_sbuf_line(txt, buffer.current_addr)
	if up then
          up.tail = buffer.search_line_node(buffer.current_addr)
	else
	  up = buffer.push_undo_atom("UADD", buffer.current_addr, buffer.current_addr)
	end
      until txt == ""
      match_found = true
    end
  end
  if not match_found and not gflags['b'] then
    error_msg "No match"
    return nil
  end
  return true
end
M.search_and_replace = search_and_replace

return M
