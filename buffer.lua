-- buffer.lua: Functions to manipulate the in-core buffer of lines for
-- a version of "ed" in Lua.
-- This module owns the line buffer and the yank buffer

local assert = assert
local concat = table.concat
local set_error_msg = function(msg)
  io.stderr.write(msg .. "/n")
end

module "buffer"

-- exported variables
current_addr = 0	-- current address in editor buffer
last_addr = 0		-- last address in editor buffer
modified = false	-- if set, buffer is different from the file

-- private variables
local buffer_head = {}		-- editor buffer (doubly linked list of lines)

function inc_current_addr()
  current_addr = current_addr + 1
  if current_addr > last_addr then
    current_addr = last_addr
  end
  return current_addr
end

function inc_addr(addr)
  return addr < last_addr and addr + 1 or 0
end

function dec_addr(addr)
  return addr > 0 and addr - 1 or last_addr
end

local function link_nodes(prev, next)
  prev.forw = next; next.back = prev
end

local function clear_buffer()
  link_nodes(buffer_head, buffer_head)
end

-- search_line_nodes():
-- return the node for the Nth line in the editor buffer
-- Speed is had by remembering the last node and line number and starting
-- from there.  This means that calls the add/delete lines must be careful
-- about their last call to search_line_node before deleting/appending.
-- A call "search_line_node(0)" resets this cache.
do
  -- Static cache of last node and its address
  local o_lp = buffer_head
  local o_addr = 0

  function search_line_node(addr)
    local lp,oa = o_lp,o_addr

    if oa < addr then
      if oa + last_addr >= 2 * addr then
	while oa < addr do
	  oa = oa + 1; lp = lp.forw
	end
      else
	lp, oa = buffer_head.back, last_addr
	while oa > addr do
	  oa = oa - 1
	  lp = lp.back
	end
      end
    else
      if oa <= 2 * addr then
	while oa > addr do
	  oa = oa - 1; lp = lp.back
	end
      else
	lp, oa = buffer_head, 0
	while oa < addr do
	  oa = oa + 1; lp = lp.forw
	end
      end
    end
    o_lp, o_addr = lp, oa
    return lp;
  end
end

-- return line number of a node
-- or nil if the node does not exist
function get_line_node_addr(lp)
  local p = buffer_head
  local addr = 0

  while p ~= lp do
    p = p.forw
    if p == buffer_head then break end
    addr = addr + 1
  end
  if addr > 0 and p == buffer_head then
    -- This happens when lp is nil, eg when querying an unset mark
    set_error_msg("Invalid address")
    return nil
  end
  return addr
end

-- insert line node into circular queue after previous
local function insert_node(lp, prev)
  link_nodes(lp, prev.forw)
  link_nodes(prev, lp)
end

-- add a node to the editor buffer after the given line number
local function add_line_node(lp, addr)
  p = search_line_node(addr)
  insert_node(lp, p)
  last_addr = last_addr + 1
end

-- return a copy of a line node, or a new node if lp is nil
local function dup_line_node(lp)
  p = {}
  if lp then p.line = lp.line end
  return p
end

--[[  Just use lp.line
function get_sbuf_line(lp)
  return lp.line
end
--]]

-- Take one line of text out of a string and add a line node to the
-- editor buffer. The line inserted is up to but not including the first
-- newline character, which is discarded.
-- Return the rest of the buffer.
function put_sbuf_line(s, addr)
  local l,rest = s:match("^([^\n]*)\n(.*)$")
  add_line_node({line=l}, addr)
  current_addr = current_addr + 1
  return rest
end


-- List of active nodes used in g/RE/cmd
-- Call sequence is always:
   -- clear_active_list()
   -- set_active_node() *
   -- ( next_active_node() + [ unset_active_nodes() * ] ) *
-- x *		zero or more repetitions of x
-- [foo]	maybe foo, maybe not.
-- a + b	a then b

do
  local active_list = {} -- array of node references (may contain nils)
  local active_len = 0	 -- maximum used index in active_list
  local active_ptr = 1	 -- index of the next item we will return when queried

  -- clear the global-active list
  function clear_active_list()
    active_list, active_len, active_ptr = {}, 0, 1
  end

  -- return the next global-active line node
  function next_active_node()
    -- Skip over lines that were included but have since been unmarked
    while active_ptr <= active_len and not active_list[active_ptr] do
      active_ptr = active_ptr + 1
    end
    if active_ptr <= active_len then
      local result = active_list[active_ptr]
      active_ptr = active_ptr + 1
      return result
    else
      return nil
    end
  end

  -- add a line node to the global-active list
  function set_active_node(lp)
    active_len = active_len + 1
    active_list[active_len] = lp
  end

  -- remove a range of lines from the global-active list,
  -- including bp but not including ep
  -- Function is called once per delete/move while performing global ops, and
  -- both the lines from bp to ep and the entries in active_list seem to be
  -- in increasing order; we use this to speed the search for each line,
  -- which will probablu be just after the last one we found.
  function unset_active_nodes(bp, ep)
    local active_ndx = 0
    while bp ~= ep do
      for i = 1, active_len do
	active_ndx = active_ndx + 1
	if active_ndx > active_len then active_ndx = 1 end

        if active_list[active_ndx] == bp then
	  active_list[active_ndx] = nil
	  break  -- out of "for"
	end
      end
      bp = bp.forw
    end
  end

end


-- insert text after line n, 
-- If not isglobal, read lines from stdin and stop when a single period is read.
-- For global operations, ibuf consists of several concatenated lines,
-- each terminated by \n.
-- Return the unused part of ibuf on success or nil on failure

function append_lines(ibuf, addr, isglobal, get_tty_line)
  current_addr = addr
  while true do
    if not isglobal then
      ibuf = get_tty_line()
      if not ibuf then break end   -- return nil
    else
      if #ibuf == 0 then break end -- return success
    end
    if ibuf:match("^%.\n") then
      ibuf = ibuf:sub(3)
      break
    end
    ibuf = put_sbuf_line(ibuf, current_addr)
    -- UNDO
    modified = true
  end
  return ibuf
end


-- Yank/put buffer and its functions
do
  -- The yank buffer, a circular doubly linked list of nodes,
  -- the same as the line buffer
  local yank_buffer_head = {}

  function clear_yank_buffer()
    link_nodes(yank_buffer_head, yank_buffer_head)
  end

  -- copy a range of lines to the cut buffer
  function yank_lines(from, to)
    local ep = search_line_node(inc_addr(to))
    local bp = search_line_node(from)
    local lp = yank_buffer_head

    clear_yank_buffer()
    while bp ~= ep do
      local p = dup_line_node(bp)
      insert_node(p, lp)
      bp = bp.forw; lp = p
    end
  end

  -- append lines from the yank buffer
  -- returns true on success, nil on failure
  function put_lines(addr)
    local lp = yank_buffer_head.forw

    if lp == yank_buffer_head then
      set_error_msg("Nothing to put")
      return nil
    end
    current_addr = addr
    while lp ~= yank_buffer_head do
      local p = dup_line_node(lp)
      add_line_node(p, current_addr)
      current_addr = current_addr + 1
      -- UNDO
      modified = true
      lp = lp.forw
    end
    return true
  end
end

-- copy a range of lines elsewhere in the buffer
function copy_lines(first_addr, second_addr, addr)
  local np = search_line_node(first_addr)
  -- UNDO
  local n = second_addr - first_addr + 1
  local m = 0

  current_addr = addr
  if addr >= first_addr and addr < second_addr then
    n = addr - first_addr + 1
    m = second_addr - addr
  end
  while n > 0 do
    while n > 0 do
      n = n - 1
      local lp = dup_line_node(np)
      add_line_node(lp, current_addr)
      current_addr = current_addr + 1
      -- UNDO
      modified = true
      np = np.forw
    end
    n = n - 1
    n,m,np = m,0,search_line_node(current_addr + 1)
  end
end

-- delete a range of lines
function delete_lines(from, to, isglobal)
  local n, p

  yank_lines(from, to)
  -- UNDO
  n = search_line_node(inc_addr(to))
  p = search_line_node(from - 1)
  if isglobal then unset_active_nodes(p.forw, n) end
  link_nodes(p, n)
  last_addr = last_addr - (to - from + 1)
  current_addr = from - 1
  modified = true
end

-- replace a range of lines with the joined text of those lines
function join_lines(from, to, isglobal)
  local lines = {}
  local ep = search_line_node(inc_addr(to))
  local bp = search_line_node(from)

  while bp ~= ep do
    lines[#lines + 1] = bp.line
    bp = bp.forw
  end
  lines[#lines + 1] = "\n"
  delete_lines(from, to, isglobal)
  current_addr = from - 1
  put_sbuf_line(concat(lines), current_addr)
  -- UNDO
  modified = true
end

-- move a range of lines
function move_lines(first_addr, second_addr, addr, isglobal)
  local b1, a1, b2, a2
  local n = inc_addr(second_addr)
  local p = first_addr - 1

  if addr == first_addr - 1 or addr == second_addr then
    a2 = search_line_node(n)
    b2 = search_line_node(p)
    current_addr = second_addr
  else
    --UNDO
    a1 = search_line_node(n)
    if addr < first_addr then
      b1 = search_line_node(p)
      b2 = search_line_node(addr)
    else
      b2 = search_line_node(addr)
      b1 = search_line_node(p)
    end
    a2 = b2.forw
    link_nodes(b2, b1.forw)
    link_nodes(a1.back, a2)
    link_nodes(b1, a1)
    current_addr = addr + (addr < first_addr
                           and second_addr - first_addr + 1
			   or 0)
  end
  if isglobal then unset_active_nodes(b2.forw, a2) end
  modified = true
end

-- Mark and unmark lines.
-- Note that "mark" is called with a line number, and is called externally
-- but "unmark" is called with a node address and is only called from this file.
local unmark_line_node

do

  local mark = {}		-- line markers, indexed by 'a'-'z'

  function mark_line_node(addr, c)
    if not c:match("^[a-z]$") then
      set_error_msg("Invalid mark character")
      return nil
    end
    local lp = search_line_node(addr)
    mark[c] = lp
    return true
  end

  -- Used in undo code
  function unmark_line_node(lp)
    for c,node in pairs(mark) do
      if node == lp then mark[c] = nil end
    end
  end

  -- return address of a marked line
  function get_marked_node_addr(c)
    if not c:match("^[a-z]$") then
      set_error_msg "Invalid mark character"
      return nil
    end
    return get_line_node_addr(mark[c])
  end

end


function init()
  clear_buffer()
  clear_yank_buffer()
end


-- UNDO code goes here
