-- mainloop.lua: Main loop of a version of "ed" in Lua.


-- First, two utility functions used by the other modules

-- Parse a positive integer from the buffer, which is guaranteed to start
-- with a digit.  Return its value and the rest of the buffer
function parse_int(ibuf)
  local n
  n,ibuf = ibuf:match("^(%d+)(.*)$")
  return tonumber(n), ibuf
end

-- Usually we always prints a prompt and error messages.
-- "verbose" and "prompt_on" allow these to be toggled
-- with the H and P commands
-- and to disable them by default when running scripted (ed -s or ed -)
local verbose = true
local prompt_on = true

-- To catch the case of things returning nil with a missing error message
-- we remember whether we just printed an error or not.
local just_printed_error_msg = nil

-- We remember the last error message that was printed so that we can
-- implement the 'h' command.
local last_error_msg = nil

-- Print an error message
function error_msg (msg)
  if verbose then
    io.stderr:write(msg .."\n")
  else
    io.stderr:write("?\n")
  end
  just_printed_error_msg = true
  last_error_msg = msg
end

local function print_last_error_msg()
  if last_error_msg then
    io.stderr:write(last_error_msg .. "\n")
  end
end


-- Import modules
local buffer = require "buffer"
local inout  = require "inout"
local regex  = require "regex"


local mainloop = {}                -- the module table

-- Persistent local variables

local def_filename = nil    -- default filename. Has to be external bcos
local first_addr, second_addr = 0, 0	-- addresses preceding a command letter

-- Export a function to set the default filename, since ed.lua needs this
function mainloop.set_def_filename(filename)
  def_filename = filename
end


local prompt, set_prompt	--  forward declaration of file-local functions
do 
  local prompt_str = "*"	-- command-line prompt (and its default)

  function prompt()
    if prompt_on then io.stderr:write(prompt_str) end
  end

  function set_prompt(str)
    prompt_str = str
  end

end


-- Drop all space characters from the start of a string (which is always ibuf)
-- except for newline
local function skip_blanks(s)
  return s:match("^[ \f\r\t\v]*(.*)$");
end


-- get_filename()
-- Extract and return the filename in the command buffer,
-- skipping leading blanks and eliminating "\\n" sequences.
-- At entry, the first char in ibuf is the space before the filename
-- or "\n" if the command was not given a filename parameter.
-- returns
  -- the filename and the rest of ibuf on success
  -- nil on errors (such as EOF from get_tty_line())
  -- "" if no filename was supplied
-- The "silent" flag, if true, means don't generate error messages and
-- don't use the default filename. It's used for reading the prompt string
-- after our P command.
local function get_filename(ibuf, silent)
  local filename
  ibuf = skip_blanks(ibuf)
  if not ibuf:match("^\n") then
    ibuf = inout.get_extended_line(ibuf, true)
    if not ibuf then return nil end
    if not silent and ibuf:match("^!") then
      error_msg "Shell commands are not implemented"
      return nil
    end
  else
    if not silent and not def_filename then
      error_msg "No current filename"
      return nil
    end
  end
  --truncate at the first newline; remove filename and newline from ibuf
  filename,ibuf = ibuf:match("^([^\n]*)\n(.*)$")	
  return filename,ibuf
end

local function invalid_address()
  error_msg "Invalid address"
  return nil
end

-- Variable used by extract_addr_range and set by next_addr
local extract_addr_range	-- forward declaration
do
  local addr_cnt

-- return 
  -- the next line address in the command buffer
  -- -1 if there are no more addresses (but the syntax was OK)
  -- nil if the address has a syntax or logical error
-- and the uneaten parts of the command line
  local function next_addr(ibuf)
    ibuf = skip_blanks(ibuf)
    local addr = buffer.current_addr
    local first = true
    local ch

    while true do
      ch, ibuf = ibuf:match("^(.)(.*)$")

      if ch:match("%d") then
	if not first then invalid_address() return nil end
	addr,ibuf = parse_int(ch..ibuf)

      elseif ch:match("[%+\t %-]") then
	ibuf = skip_blanks(ibuf)
	if ibuf:match("^%d") then
	  local n
	  n,ibuf = parse_int(ibuf)
	  addr = addr + ((ch == '-') and -n or n)
	elseif ch == '+' then
	  addr = addr + 1
	elseif ch == '-' then
	  addr = addr - 1
	end

      elseif ch:match("[%.%$]") then
	if not first then return invalid_address() end
	addr = (ch == '.') and buffer.current_addr or buffer.last_addr

      elseif ch:match("[/%?]") then
	if not first then return invalid_address() end
	addr,ibuf = regex.next_matching_node_addr(ch..ibuf, ch == '/')
	if not addr then return nil end
	if ch == ibuf:sub(1,1) then ibuf = ibuf:sub(2) end

      elseif ch:match("'") then
	if not first then return invalid_address() end
	addr = buffer.get_marked_node_addr(ibuf:sub(1,1))
	ibuf = ibuf:sub(2)
	if not addr then return nil end

      else
        if ch:match("[%%,;]") and first then
	    addr_cnt = addr_cnt + 1
	    second_addr = (ch == ';') and buffer.current_addr or 1
	    addr = buffer.last_addr
	else
	  -- default case
	  ibuf = ch..ibuf
	  if first then return -1,ibuf end	-- Syntax OK but no address
	  if addr < 0 or addr > buffer.last_addr then
	    return invalid_address()
	  end
	  addr_cnt = addr_cnt + 1
	  return addr,ibuf
	end
      end

      first = false
    end
  end

  -- get line addresses from the command buffer until an invalid address is seen
  -- Returns the number of addresses read plus the rest of the command line
  -- or nil on error
  function extract_addr_range(ibuf)
    local addr

    addr_cnt = 0
    first_addr = buffer.current_addr
    second_addr = first_addr

    while true do
      addr,ibuf = next_addr(ibuf)
      if not addr then return nil end  -- syntax or logical error in addresses
      if addr == -1 then break end
      first_addr, second_addr = second_addr, addr
      if not ibuf:match("^[,;]") then break end
      if ibuf:match("^;") then buffer.current_addr = addr end
      ibuf = ibuf:sub(2)
    end
    if addr_cnt == 1 or second_addr ~= addr then
      first_addr = second_addr
    end
    return addr_cnt,ibuf   -- zero or more addresses extracted
  end
  mainloop.extract_addr_range = extract_addr_range

end

-- get a valid address from the command line
-- returns the address and the rest of the command line on success
-- or nil on failure
local function get_third_addr(ibuf)
  local old1 = first_addr
  local old2 = second_addr
  local addr_cnt
  addr_cnt,ibuf = extract_addr_range(ibuf)
  if not addr_cnt then return nil end
  if second_addr < 0 or second_addr > buffer.last_addr then
    return invalid_address()
  end
  local addr = second_addr
  first_addr, second_addr = old1, old2
  return addr,ibuf
end

-- return true if the address range is valid, false/nil otherwise.
local function check_addr_range(n, m, addr_cnt)
  if addr_cnt == 0 then
    first_addr, second_addr = n, m
  end
  if first_addr < 1 or first_addr > second_addr
     or second_addr > buffer.last_addr then
    return invalid_address()
  end
  return true
end

local function check_current_addr(addr_cnt)
  return check_addr_range( buffer.current_addr, buffer.current_addr, addr_cnt)
end

-- get_command_suffix()
-- verify the command suffix in the command buffer.
-- gflags is a set: if gflags["l"] is not nil, then flag 'l' is set.
-- returns the new value of gflags and the rest of ibuf on success
-- or the original value of gflags and nil on failure
local function get_command_suffix(ibuf,gflags)
  while ibuf:match("^[lnp]") do
    local flag = ibuf:sub(1,1)
    gflags[flag] = true
    ibuf = ibuf:sub(2)
  end
  if not ibuf:match("^\n") then
    error_msg "Invalid command suffix"
    return gflags,nil
  end
  ibuf = ibuf:sub(2) -- eat the newline
  return gflags,ibuf
end

local function unexpected_address(addr_cnt)
  if addr_cnt > 0 then
    error_msg "Unexpected address"
    return true
  end
  return false
end

local function unexpected_command_suffix(ibuf)
  if not ibuf:match("^%s") then
    error_msg "Unexpected command suffix"
    return true
  end
  return false
end

-- Are any flags set in the given set?
-- Could be local to command_s and exec_*
local function flags_are_set(flags)
  for i,v in pairs(flags) do
    return true
  end
  return false
end

local command_s		-- put command_s in file-local scope
do
  -- static data for 's' command
  local gflags = {}		-- Persistent flags for substitution commands
	-- 'b'	 Substitution is global (part of a g/RE/s... command
	-- [pnl] line-printing flags: print, numerate, list
	-- 'g'	 The trailing 'g' flag to substitute all occurrences in a line
  local snum = 0		-- which occurrence to substitute (s2/a/b)

  -- execute substitution command
  -- returning the new value of gflagsp and the rest of ibuf on success
  -- or nil on failure

  function command_s(ibuf, gflagsp, addr_cnt, isglobal)
    -- sflags is a set of lower case characters:
    -- 'g'  complement previous global substitution suffix
    -- 'p'  complement previous print suffix
    -- 'r'  use last regex instead of last pattern
    -- 'f'  repeat last substitution ("1,$s")
    -- To set a flag, use sflags[flag] = true
    local sflags = {}

    -- First, handle the 1,5s form with optional integer and [gpr] suffixes
    -- In the following code, "flags_are_set(sflags)" means the command
    -- had this form to repeat the previous substitution.
    repeat
      if ibuf:match("^%d") then
	snum,ibuf = parse_int(ibuf)
	sflags['f'] = true  gflags['g'] = nil	-- override g
      else
	local ch = ibuf:sub(1,1)
	if ch == '\n' then
	  sflags['f'] = true
	elseif ch:match("[gpr]") then
	  sflags[ch] = true
	  ibuf = ibuf:sub(2)
	else
	  if flags_are_set(sflags) then
	    -- Can this ever happen?
	    error_msg "Invalid command suffix"
	    return nil
	  end
	end
      end
    until not flags_are_set(sflags) or ibuf:match("^\n")
    if flags_are_set(sflags) and not regex.prev_pattern() then
      error_msg "No previous substitution"
      return nil
    end
    if sflags['g'] then snum = nil end	-- 'g' overrides numeric arg
    if ibuf:match("^[^\n]\n") then
      error_msg "Invalid pattern delimiter"
      return nil
    end
    -- BUG?: I don't understand this. 'r' should use last search regex
    -- instead of the LHS of the last substitution
    -- but *this* seems to be what the ed-1.5 source says.
    if not flags_are_set(sflags) or sflags['r'] then
      ibuf = regex.new_compiled_pattern(ibuf)
      if not ibuf then return nil end
    end
    if not flags_are_set(sflags) then
      gflags,snum,ibuf = regex.extract_subst_tail(ibuf, isglobal)
      if not gflags then return nil end
    end
    gflags['b'] = isglobal and true or nil
    if sflags['g'] then
      gflags['g'] = (not gflags['g']) and true or nil	-- invert gflags['g']
    end
    if sflags['p'] then
      gflags['p'] = (not gflags['p']) and true or nil	-- invert gflags['p']
      gflags['l'] = nil
      gflags['n'] = nil
    end
    if ibuf:match("^[lnp]") then
      local flag = ibuf:sub(1,1)
      ibuf = ibuf:sub(2)
      gflags[flag] = true
    end
    if not check_current_addr(addr_cnt) then return nil end
    gflagsp,ibuf = get_command_suffix(ibuf, gflagsp)
    if not ibuf then return nil end
    if not isglobal then buffer.clear_undo_stack() end
    if not regex.search_and_replace(first_addr, second_addr,
				    gflags, snum, isglobal) then
      return nil
    end
    if gflags['p'] or gflags['l'] or gflags['n'] then
      inout.display_lines(buffer.current_addr, buffer.current_addr, gflags)
    end
    return gflagsp,ibuf
  end

end

-- forward declaration of mutually recursive functions
-- sharing persistent private variables
local exec_global
local exec_command

-- exec_command(ibuf, prev_status, isglobal)
-- execute the next command in the command buffer
-- returns
   -- nil on error
   -- "" and the rest of the command buffer on success,
   -- "QUIT" if we should quit the program due to a q/Q/wq command.
-- We implement each command's code as an function entry in a table
-- indexed by the command letters, where the function is passed the
-- command character that invoked it followed by the rest of
-- exec_command()'s arguments and returns the same values as exec_command().
do
  local gflags = {}	-- persistent flags
  local addr_cnt	-- How many addresses were supplied?
  local fnp		-- filename temp used by various commands
  local command = {}	-- table mapping command letters to functions

  command.a = function(c, ibuf, _, isglobal)
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not ibuf then return nil end
    if not isglobal then buffer.clear_undo_stack() end
    ibuf = buffer.append_lines(ibuf, second_addr, isglobal,
			       inout.get_tty_line)
    if not ibuf then return nil end
    return "",ibuf
  end

  command.c = function(c, ibuf, _, isglobal)
    if first_addr == 0 then first_addr = 1 end
    if second_addr == 0 then second_addr = 1 end
    if not check_current_addr(addr_cnt) then return nil end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not ibuf then return nil end
    if not isglobal then buffer.clear_undo_stack() end
    buffer.delete_lines(first_addr, second_addr, isglobal)
    ibuf = buffer.append_lines(ibuf, buffer.current_addr, isglobal,
			       inout.get_tty_line)
    if not ibuf then return nil end
    return "",ibuf
  end

  command.d = function(c, ibuf, _, isglobal)
    if check_current_addr(addr_cnt) then
      gflags,ibuf = get_command_suffix(ibuf,gflags)
      if not ibuf then return nil end
    else
      return nil
    end
    if not isglobal then buffer.clear_undo_stack() end
    buffer.delete_lines(first_addr, second_addr, isglobal)
    buffer.inc_current_addr()
    return "",ibuf
  end

  command.e = function(c, ibuf, prev_status, isglobal)
    if c == 'e' and buffer.modified and not scripted and prev_status ~= "EMOD"
    then
      error_msg "Buffer is modified"
      return "EMOD"
    end
    if unexpected_address(addr_cnt) or
       unexpected_command_suffix(ibuf) then
      return nil
    end
    fnp,ibuf = get_filename(ibuf)
    if not fnp then return nil end
    buffer.delete_lines(1, buffer.last_addr, isglobal)  --TODO clear_buffer()
    buffer.clear_undo_stack()	-- save memory
    if #fnp > 0 then def_filename = fnp end	-- SHELL
    if not inout.read_file(#fnp > 0 and fnp or def_filename, 0) then
      return nil
    end
    buffer.reset_undo_state()
    buffer.modified = false
    return "",ibuf
  end
  command.E = command.e

  command.f = function(c, ibuf, _, isglobal)
    if unexpected_address(addr_cnt) or
       unexpected_command_suffix(ibuf) then
      return nil
    end
    fnp,ibuf = get_filename(ibuf)
    if not fnp then return nil end
    if fnp:match("^!") then
      error_msg "Invalid redirection"
      return nil
    end
    if #fnp > 0 then def_filename=fnp end
    print(def_filename)
    return "",ibuf
  end

  -- 'g' 'v' 'G' 'V'
  command.g = function(c, ibuf, _, isglobal)
    if isglobal then
      error_msg "Cannot nest global commands"
      return nil
    end
    local n = (c == 'g') or (c == 'G')
    if not check_addr_range(1, buffer.last_addr, addr_cnt) then
      return nil
    end
    ibuf = regex.build_active_list(ibuf, first_addr, second_addr, n)
    if not ibuf then return nil end
    n = (c == 'G') or (c == 'V')
    if n then
      gflags,ibuf = get_command_suffix(ibuf,gflags)
      if not ibuf then return nil end
    end
    local status
    status,ibuf = exec_global(ibuf, gflags, n)
    if not status then return nil end
    return "",ibuf
  end
  command.v = command.g
  command.G = command.g
  command.V = command.g

  -- 'h' 'H'
  command.h = function(c, ibuf, _, isglobal)
    -- 'h' prints the error message from the last error that was generated
    -- 'H' toggles the printing of verbose error messages and, if this leaves
    --     it on, prints the last error message
    if unexpected_address(addr_cnt) then return nil end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not ibuf then return nil end
    if c == 'H' then verbose = not verbose end
    print_last_error_msg()
    return "",ibuf
  end
  command.H = command.h

  command.i = function(c, ibuf, _, isglobal)
    if second_addr == 0 then second_addr = 1 end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not ibuf then return nil end
    if not isglobal then buffer.clear_undo_stack() end
    ibuf = buffer.append_lines(ibuf, second_addr - 1, isglobal,
			       inout.get_tty_line)
    if not ibuf then return nil end
    return "",ibuf
  end

  command.j = function(c, ibuf, _, isglobal)
    if not check_addr_range(buffer.current_addr, buffer.current_addr + 1,
			       addr_cnt) then return nil end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not ibuf then return nil end
    if not isglobal then buffer.clear_undo_stack() end
    if first_addr ~= second_addr then
      buffer.join_lines(first_addr, second_addr, isglobal)
    end
    return "",ibuf
  end

  command.k = function(c, ibuf, _, isglobal)
    local n
    n, ibuf = ibuf:match("^(.)(.*)$")
    if second_addr == 0 then
      return invalid_address()
    end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not ibuf or
       not buffer.mark_line_node(second_addr, n) then
      return nil
    end
    return "",ibuf
  end

  command.m = function(c, ibuf, _, isglobal)
    if not check_current_addr(addr_cnt) then return nil end
    local addr
    addr,ibuf = get_third_addr(ibuf)
    if not addr then return nil end
    if addr >= first_addr and addr < second_addr then
      error_msg "Invalid destination"  return nil
    end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not ibuf then return nil end
    if not isglobal then buffer.clear_undo_stack() end
    buffer.move_lines(first_addr, second_addr, addr, isglobal)
    return "",ibuf
  end

   -- 'l' 'n' 'p'
  command.p = function(c, ibuf, _, isglobal)
    if not check_current_addr(addr_cnt) then return nil end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not ibuf then return nil end
    gflags[c] = true
    inout.display_lines(first_addr, second_addr, gflags)
    gflags = {}
    return "",ibuf
  end
  command.l = command.p
  command.n = command.p

  command.P = function(c, ibuf, _, isglobal)
    -- In GNU ed, P toggles the printing of the prompt.
    -- Here, an optional filename-style argument sets the prompt string
    -- (and turns prompt-printing on)
    if unexpected_command_suffix(ibuf) then return nil end
    local prompt
    prompt,ibuf = get_filename(ibuf, true)
    if prompt == "" then
      prompt_on = not prompt_on
    else
      set_prompt(prompt)
      prompt_on = true
    end
    return "",ibuf
  end

  -- 'q' 'Q'
  command.q = function(c, ibuf, prev_status, isglobal)
    if unexpected_address(addr_cnt) then return nil end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not ibuf then return nil end
    if buffer.modified and not scripted and c == 'q' and prev_status ~= "EMOD"
    then
      error_msg "Buffer is modified"
      return "EMOD"
    else
      return "QUIT"
    end
    return "",ibuf
  end
  command.Q = command.q

  command.r = function(c, ibuf, _, isglobal)
    if unexpected_command_suffix(ibuf) then return nil end
    if addr_cnt == 0 then second_addr = buffer.last_addr end
    fnp,ibuf = get_filename(ibuf)
    if not fnp then return nil end
    if not isglobal then buffer.clear_undo_stack() end
    if not def_filename and not fnp:match("^!") then
      def_filename = fnp
    end
    addr = inout.read_file(#fnp > 0 and fnp or def_filename, second_addr)
    if not addr then return nil end
    --if addr > 0 and addr ~= buffer.last_addr then buffer.modified = true end
    if addr > 0 then buffer.modified = true end
    return "",ibuf
  end

  command.s = function(c, ibuf, _, isglobal)
    gflags,ibuf = command_s(ibuf, gflags, addr_cnt, isglobal)
    if not gflags then return nil end
    return "",ibuf
  end

  command.t = function(c, ibuf, _, isglobal)
    if not check_current_addr(addr_cnt) then return nil end
    addr,ibuf = get_third_addr(ibuf)
    if not addr then return nil end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not ibuf then return nil end
    if not isglobal then buffer.clear_undo_stack() end
    buffer.copy_lines(first_addr, second_addr, addr)
    return "",ibuf
  end

  command.u = function(c, ibuf, _, isglobal)
    if unexpected_address(addr_cnt) then return nil end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not ibuf then return nil end
    buffer.undo(isglobal)
    return "",ibuf
  end

  -- 'w' 'W'
  command.w = function(c, ibuf, prev_status, isglobal)
    local n = ibuf:sub(1,1)
    if n:match("[qQ]") then ibuf = ibuf:sub(2) end
    if unexpected_command_suffix(ibuf) then return nil end
    fnp,ibuf = get_filename(ibuf)
    if not fnp then return nil end
    if addr_cnt == 0 and buffer.last_addr == 0 then
      first_addr, second_addr = 0, 0
    elseif not check_addr_range(1, buffer.last_addr, addr_cnt) then
      return nil
    end
    if not def_filename then def_filename = fnp end
    addr = inout.write_file(#fnp > 0 and fnp or def_filename,
			    (c == 'W') and "a" or "w",
			    first_addr, second_addr)
    if not addr then return nil end
    if addr == buffer.last_addr then
      buffer.modified = false
    elseif buffer.modified and not scripted and n == 'q'
           and prev_status ~= "EMOD" then
      error_msg "Buffer is modified"
      return "EMOD"
    end
    if n:match("[qQ]") then return "QUIT" end
    return "",ibuf
  end
  command.W = command.w

  command.x = function(c, ibuf, _, isglobal)
    if second_addr < 0 or buffer.last_addr < second_addr then
      return invalid_address()
    end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not ibuf then return nil end
    if not isglobal then buffer.clear_undo_stack() end
    if not buffer.put_lines(second_addr) then return nil end
    return "",ibuf
  end

  command.y = function(c, ibuf, _, isglobal)
    if not check_current_addr(addr_cnt) then return nil end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not ibuf then return nil end
    buffer.yank_lines(first_addr, second_addr)
    return "",ibuf
  end

  command.z = function(c, ibuf, _, isglobal)
    first_addr = 1
    if not check_addr_range(first_addr,
			    buffer.current_addr + (isglobal and 0 or 1),
			    addr_cnt) then return nil end
    if ibuf:match("^%d") then
      inout.window_lines,ibuf = parse_int(ibuf)
    end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not ibuf then return nil end
    inout.display_lines(second_addr,
			math.min(buffer.last_addr,
				 second_addr + inout.window_lines),
			gflags)
    gflags = {}
    return "",ibuf
  end
  
  command['='] = function(c, ibuf, _, isglobal)
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not ibuf then return nil end
    print( (addr_cnt > 0) and second_addr or buffer.last_addr )
    return "",ibuf
  end

  command['!'] = function(c, ibuf, _, isglobal)
    if unexpected_address(addr_cnt) then return nil end
    -- TODO
    error_msg "Shell commands are not implemented"
    return nil
  end

  command['\n'] = function(c, ibuf, _, isglobal)
    first_addr = 1
    if not check_addr_range(first_addr,
			    buffer.current_addr + (isglobal and 0 or 1),
			    addr_cnt) then return nil end
    inout.display_lines(second_addr, second_addr, {})
    return "",ibuf
  end

  command['#'] = function(c, ibuf, _, isglobal)
    -- Discard up to first newline.
    -- If there is no newline, match returns nil (discarding the whole line)
    ibuf = ibuf:match("^[^\n]*\n(.*)$")

    -- EOF in the middle of a line is not normal.
    if not ibuf then return nil end

    return "",ibuf
  end

  function exec_command(ibuf, prev_status, isglobal)
    local c		-- command character

    addr_cnt,ibuf = extract_addr_range(ibuf)
    if not addr_cnt then return nil end

    ibuf = skip_blanks(ibuf)
    c, ibuf = ibuf:match("^(.)(.*)$")

    -- TODO: gflags sometimes gets left as nil from a failure return value.
    -- We should change everything to return nil ibuf as the first parameter
    -- instead of nil gflags as the 1st param.
    if not gflags then gflags = {} end

    if command[c] then
      return command[c](c, ibuf, prev_status, isglobal)
    else
      error_msg "Unknown command"
      return nil
    end

    -- When does this test come into play?
    if flags_are_set(gflags) then
       inout.display_lines(buffer.current_addr, buffer.current_addr, gflags)
    end

    return "", ibuf
  end

end
mainloop.exec_command = exec_command

-- apply command list in the command buffer to active lines in a range.
-- Return nil on errors, true otherwise, plus the remainder of ibuf on success
-- Function is local with forward declaration above exec_command


--[[local]] function exec_global(ibuf, gflags, interactive)
  local cmd = nil	-- last command that was applied globally
			-- (used in interactive mode's "&" command)

  if not interactive then
    if ibuf == "\n" then
      cmd = "p\n"	-- null command list == 'p'
    else
      ibuf = inout.get_extended_line(ibuf, false) 
      if not ibuf then return nil end
      cmd = ibuf
    end
  end
  buffer.clear_undo_stack()
  while true do
    local continue = nil	-- Implementing C in Lua, sigh!
    local lp = buffer.next_active_node()
    if not lp then break end
    buffer.current_addr = buffer.get_line_node_addr(lp)
    if not buffer.current_addr then return nil end
    if interactive then
      -- print current address; get a command in global syntax
      inout.display_lines(buffer.current_addr, buffer.current_addr, gflags)
      ibuf = inout.get_tty_line()
      if not ibuf then return nil end
      if #ibuf == 0 then
        error_msg "Unexpected end-of-file";
	return nil
      end
      if ibuf == "\n" then	-- do nothing
        continue = true
      end
      if not continue then
        if ibuf == "&\n" then  -- repeat previous cmd
	  if not cmd then error_msg "No previous command" return nil end
	else
	  ibuf = inout.get_extended_line(ibuf, false)
	  if not ibuf then return nil end
	  cmd = ibuf
	end
      end
    end
    if not continue then
      ibuf = cmd
      while #ibuf > 0 do
	local status
	status,ibuf = exec_command(ibuf, "", true)
	if not (status == "") then return nil end
      end
    end
  end
  return true, ibuf
end
mainloop.exec_global = exec_global

-- Read an ed command from the input and execute it.
-- Returns true unless the editor should quit.
local read_and_run_command    -- forward declaration
do
  -- persistent local variable, since exec_command() needs to know the status
  -- of the previous command so that "q;q" or e;e" ignore the previous
  -- "Buffer modified" (status == "EMOD") warning.
  local status = ""

  function read_and_run_command()
    local ibuf = nil          -- the command line string
    local ok

    ok,ibuf = pcall(inout.get_tty_line)
    if not ok then
      error_msg(ibuf)
      return true
    end

    -- EOF or error reading input
    if not ibuf then
      if not buffer.modified or scripted then return nil end
      error_msg("Warning: buffer modified")
      buffer.modified = false	-- So that we exit if they ^D again
      status = "EMOD"
      return true	-- continue
    end

    just_printed_error_msg = false

    -- used for debug to get a stack backtrace on runtime errors or interrupts
    local die_on_errors = false

    if die_on_errors then
      status,ibuf = exec_command(ibuf, status, false)
    else
      -- Use pcall in the hope that bugs don't junk the editor session
      ok,status,ibuf = pcall(exec_command, ibuf, status, false)
      if not ok then
	error_msg(status)
      end
    end

    -- status=nil means there was some error. Catch bugs where an error code
    -- is returned but we never printed an error message. Should never happen.
    if status == nil and not just_printed_error_msg then
      error_msg "Something went wrong"
    elseif status == "QUIT" then
      return nil
    end

    return true
  end
end

function mainloop.main_loop()
  if scripted then
    verbose,prompt_on = nil,nil
  end
  repeat prompt() until not read_and_run_command()
  return last_error_msg and 1 or 0
end


return mainloop		-- end of module
