-- buffer.lua: Functions to manipulate the in-core buffer of lines for
-- a version of "ed" in Lua.
-- This module owns the line buffer and the yank buffer


local M = {}		-- the module table

-------------------- Code to handle the buffer of lines --------------------

-- exported variables
M.current_addr = 0	-- current address in editor buffer
M.last_addr = 0		-- last address in editor buffer
M.modified = false	-- if set, buffer is different from the file

-- private variables
local buffer_head = {}		-- editor buffer (doubly linked list of lines)


local function inc_current_addr()
  M.current_addr = M.current_addr + 1
  if M.current_addr > M.last_addr then
    M.current_addr = M.last_addr
  end
  return M.current_addr
end
M.inc_current_addr = inc_current_addr

local function inc_addr(addr)
  return addr < M.last_addr and addr + 1 or 0
end
M.inc_addr = inc_addr

local function dec_addr(addr)
  return addr > 0 and addr - 1 or M.last_addr
end
M.dec_addr = dec_addr

local function link_nodes(prev, next)
  prev.forw = next; next.back = prev
end
M.link_nodes = link_nodes


local function clear_buffer()
  link_nodes(buffer_head, buffer_head)
end


-- search_line_nodes():
-- return the node for the Nth line in the editor buffer
-- Speed is had by remembering the last node and line number and starting
-- from there.  This means that calls the add/delete lines must be careful
-- about their last call to search_line_node before deleting/appending.
-- A call "search_line_node(0)" resets this cache.
local search_line_node
do
  -- Static cache of last node and its address
  local o_lp = buffer_head
  local o_addr = 0

  function search_line_node(addr)
    local lp,oa = o_lp,o_addr

    if oa < addr then
      if oa + M.last_addr >= 2 * addr then
	while oa < addr do
	  oa = oa + 1; lp = lp.forw
	end
      else
	lp, oa = buffer_head.back, M.last_addr
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
M.search_line_node = search_line_node

-- return line number of a node
-- or nil if the node does not exist
local function get_line_node_addr(lp)
  local p = buffer_head
  local addr = 0

  while p ~= lp do
    p = p.forw
    if p == buffer_head then break end
    addr = addr + 1
  end
  if addr > 0 and p == buffer_head then
    -- This happens when lp is nil, eg when querying an unset mark
    error_msg "Invalid address"
    return nil
  end
  return addr
end
M.get_line_node_addr = get_line_node_addr

-- insert line node into circular queue after previous
local function insert_node(lp, prev)
  link_nodes(lp, prev.forw)
  link_nodes(prev, lp)
end
-- not exported

-- add a node to the editor buffer after the given line number
local function add_line_node(lp, addr)
  p = search_line_node(addr)
  insert_node(lp, p)
  M.last_addr = M.last_addr + 1
end
-- not exported


-- return a copy of a line node, or a new node if lp is nil
local function dup_line_node(lp)
  p = {}
  if lp then p.line = lp.line end
  return p
end
-- not exported


--[[  Just use lp.line
function get_sbuf_line(lp)
  return lp.line
end
--]]

-- Take one line of text out of a string and add a line node to the
-- editor buffer. The line inserted is up to but not including the first
-- newline character, which is discarded.
-- Return the rest of the buffer.
local function put_sbuf_line(s, addr)
  local l,rest = s:match("^([^\n]*)\n(.*)$")
  add_line_node({line=l}, addr)
  M.current_addr = M.current_addr + 1
  return rest
end
M.put_sbuf_line = put_sbuf_line

-------------------- Code to handle line marks --------------------

-- Mark and unmark lines.
-- Note that "mark" is called with a line number, and is called externally
-- but "unmark" is called with a node address and is only called from this file.
local mark_line_node
local unmark_line_node
local get_marked_line_node
do

  local mark = {}		-- line markers, indexed by 'a'-'z'

  function mark_line_node(addr, c)
    if not c:match("^[a-z]$") then
      error_msg "Invalid mark character"
      return nil
    end
    local lp = search_line_node(addr)
    mark[c] = lp
    return true
  end
  M.mark_line_node = mark_line_node

  -- Used in undo code
  function unmark_line_node(lp)
    for c,node in pairs(mark) do
      if node == lp then mark[c] = nil end
    end
  end
  M.unmark_line_node = unmark_line_node

  -- return address of a marked line
  function get_marked_node_addr(c)
    if not c:match("^[a-z]$") then
      error_msg "Invalid mark character"
      return nil
    end
    return get_line_node_addr(mark[c])
  end
  M.get_marked_node_addr = get_marked_node_addr

end

---------- Code to handle mark/sweep of lines used in g commands ----------

-- List of active nodes used in g/RE/cmd
-- Call sequence is always:
   -- clear_active_list()
   -- set_active_node() *
   -- ( next_active_node() + [ unset_active_nodes() * ] ) *
-- x *		zero or more repetitions of x
-- [foo]	maybe foo, maybe not.
-- a + b	a then b

local unset_active_nodes -- forward declaration of local function

do
  local active_list = {} -- array of node references (may contain nils)
  local active_len = 0	 -- maximum used index in active_list
  local active_ptr = 1	 -- index of the next item we will return when queried

  -- clear the global-active list
  local function clear_active_list()
    active_list, active_len, active_ptr = {}, 0, 1
  end
  M.clear_active_list = clear_active_list

  -- return the next global-active line node
  local function next_active_node()
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
  M.next_active_node = next_active_node

  -- add a line node to the global-active list
  local function set_active_node(lp)
    active_len = active_len + 1
    active_list[active_len] = lp
  end
  M.set_active_node = set_active_node

  -- remove a range of lines from the global-active list,
  -- including bp but not including ep
  -- Function is called once per delete/move while performing global ops, and
  -- both the lines from bp to ep and the entries in active_list seem to be
  -- in increasing order; we use this to speed the search for each line,
  -- which will probably be just after the last one we found.
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
  -- not exported

end

---------- Code to manage "undo" ----------

-- "Undo" keeps a stack of operations that were performed on the buffer.
-- Each node in the stack (here, an array) has fields:
   -- type: "UADD", "UDEL", "UMOV"
   -- head: pointer to the head of the list of lines involved
   -- tail: pointer to the tail of the list of lines involved

do
  -- Local persistent variables
  local ustack = {}
  -- Values to restore when undoing.  If *_addr is nil, undo is not possible.
  local u_current_addr = nil
  local u_last_addr = nil
  local u_modified = nil

  local function clear_undo_stack()
    for u_ptr = #ustack, 1, -1 do
      if ustack[u_ptr].type == "UDEL" then
        local ep = ustack[u_ptr].tail.forw
        local bp = ustack[u_ptr].head
        while bp ~= ep do
          local lp = bp.forw
	  unmark_line_node(bp)
	  bp = lp
        end
      end
    end
    ustack = {}
    u_current_addr = M.current_addr
    u_last_addr = M.last_addr
    u_modified = M.modified
  end

  local function reset_undo_state()
    clear_undo_stack()
    u_current_addr = nil
    u_last_addr = nil
    u_modified = nil
  end

  -- Put a new change on the undo stack
  local function push_undo_atom(type, from, to)
    local new = {
      type = type,
      tail = search_line_node(to),
      head = search_line_node(from)
    }
    ustack[#ustack+1] = new
    return new
  end

  local function undo(isglobal)
    if (not u_current_addr) or (not u_last_addr) then
      error_msg "Nothing to undo"
      return nil
    end

    local o_current_addr = M.current_addr
    local o_last_addr = M.last_addr
    local o_modified = M.modified

    search_line_node(0)    -- reset cached values

    local skip_next = false	--used to effect "--n" inside the loop
    for n = #ustack, 1, -1 do
      if skip_next then
        skip_next = false
      else
	if ustack[n].type == "UADD" then
	  link_nodes(ustack[n].head.back, ustack[n].tail.forw)
	  ustack[n].type = "UDEL"

	elseif ustack[n].type == "UDEL" then
	  link_nodes(ustack[n].head.back, ustack[n].head)
	  link_nodes(ustack[n].tail, ustack[n].tail.forw)
	  ustack[n].type = "UADD"

	elseif ustack[n].type == "UMOV" then
	  link_nodes(ustack[n-1].head, ustack[n].head.forw)
	  link_nodes(ustack[n].tail.back, ustack[n-1].tail)
	  link_nodes(ustack[n].head, ustack[n].tail)
	  skip_next = true	-- has the effect of "n = n - 1"

	else
	  error("Internal error: Unknown undo node type " ..
		tostring(ustack[n].type))
	end
      end
    end

    -- Reverse the undo stack order
    do
      local new_stack = {}
      for n = 1, #ustack do
	new_stack[n] = ustack[#ustack - (n-1)]
      end
      ustack, new_stack = new_stack, nil
    end

    if isglobal then
      M.clear_active_list();
    end
    M.current_addr, u_current_addr = u_current_addr, o_current_addr
    M.last_addr, u_last_addr       = u_last_addr, o_last_addr
    M.modified, u_modified         = u_modified, o_modified

    return true  -- Success
  end

  -- export the module functions
  M.clear_undo_stack = clear_undo_stack
  M.reset_undo_state = reset_undo_state
  M.push_undo_atom   = push_undo_atom
  M.undo             = undo
end

---------- Code to perform editor operations on the line buffer ----------

-- insert text after line n, 
-- If not isglobal, read lines from stdin and stop when a single period is read.
-- For global operations, ibuf consists of several concatenated lines,
-- each terminated by \n.
-- Return the unused part of ibuf on success or nil on failure

local function append_lines(ibuf, addr, isglobal, get_tty_line)
  local up = nil	-- for undo
  M.current_addr = addr
  while true do
    if not isglobal then
      ibuf = get_tty_line()
      -- EOF while reading lines terminates the reading, but is not an error
      if not ibuf then return "" end
    else
      if #ibuf == 0 then break end -- return success
    end
    if ibuf:match("^%.\n") then
      ibuf = ibuf:sub(3)
      break
    end
    ibuf = put_sbuf_line(ibuf, M.current_addr)
    if up then
      up.tail = search_line_node(M.current_addr)
    else
      up = M.push_undo_atom("UADD", M.current_addr, M.current_addr)
    end
    M.modified = true
  end
  return ibuf
end
M.append_lines = append_lines


-- Yank/put buffer and its functions
local clear_yank_buffer
local yank_lines
local put_lines
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
  M.yank_lines = yank_lines

  -- append lines from the yank buffer
  -- returns true on success, nil on failure
  function put_lines(addr)
    local lp = yank_buffer_head.forw
    local up = nil	-- for undo

    if lp == yank_buffer_head then
      error_msg "Nothing to put"
      return nil
    end
    M.current_addr = addr
    while lp ~= yank_buffer_head do
      local p = dup_line_node(lp)
      add_line_node(p, M.current_addr)
      M.current_addr = M.current_addr + 1
      if up then
        up.tail = p
      else
        up = M.push_undo_atom("UADD", M.current_addr, M.current_addr)
      end
      M.modified = true
      lp = lp.forw
    end
    return true
  end
  M.put_lines = put_lines

end

-- copy a range of lines elsewhere in the buffer
local function copy_lines(first_addr, second_addr, addr)
  local np = search_line_node(first_addr)
  local up = nil	-- for undo
  local n = second_addr - first_addr + 1
  local m = 0

  M.current_addr = addr
  if addr >= first_addr and addr < second_addr then
    n = addr - first_addr + 1
    m = second_addr - addr
  end
  while n > 0 do
    while n > 0 do
      n = n - 1
      local lp = dup_line_node(np)
      add_line_node(lp, M.current_addr)
      M.current_addr = M.current_addr + 1
      if up then
        up.tail = lp
      else
        up = M.push_undo_atom("UADD", M.current_addr, M.current_addr)
      end
      M.modified = true
      np = np.forw
    end
    n = n - 1
    n,m,np = m,0,search_line_node(M.current_addr + 1)
  end
end
M.copy_lines = copy_lines

-- delete a range of lines
local function delete_lines(from, to, isglobal)
  local n, p

  yank_lines(from, to)
  M.push_undo_atom("UDEL", from, to)
  n = search_line_node(inc_addr(to))
  p = search_line_node(from - 1)
  if isglobal then unset_active_nodes(p.forw, n) end
  link_nodes(p, n)
  M.last_addr = M.last_addr - (to - from + 1)
  M.current_addr = from - 1
  M.modified = true
end
M.delete_lines = delete_lines

-- replace a range of lines with the joined text of those lines
local function join_lines(from, to, isglobal)
  local lines = {}
  local ep = search_line_node(inc_addr(to))
  local bp = search_line_node(from)

  while bp ~= ep do
    lines[#lines + 1] = bp.line
    bp = bp.forw
  end
  lines[#lines + 1] = "\n"
  delete_lines(from, to, isglobal)
  M.current_addr = from - 1
  put_sbuf_line(table.concat(lines), M.current_addr)
  M.push_undo_atom("UADD", M.current_addr, M.current_addr)
  M.modified = true
end
M.join_lines = join_lines

-- move a range of lines
local function move_lines(first_addr, second_addr, addr, isglobal)
  local b1, a1, b2, a2
  local n = inc_addr(second_addr)
  local p = first_addr - 1

  if addr == first_addr - 1 or addr == second_addr then
    a2 = search_line_node(n)
    b2 = search_line_node(p)
    M.current_addr = second_addr
  else
    M.push_undo_atom("UMOV", p, n)
    M.push_undo_atom("UMOV", addr, inc_addr(addr))

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
    M.current_addr = addr + ((addr < first_addr)
                             and (second_addr - first_addr + 1)
			     or 0)
  end
  if isglobal then unset_active_nodes(b2.forw, a2) end
  M.modified = true
end
M.move_lines = move_lines


local function init()
  clear_buffer()
  clear_yank_buffer()
end
M.init = init

---------- All done return the module table ----------

return M
