-- mainloop.lua: Main loop of a version of "ed" in Lua.


-- First, two utility functions used by the other modules

-- Parse a positive integer from the buffer, which is guaranteed to start
-- with a digit.  Return its value and the rest of the buffer
function parse_int(ibuf)
  local n
  n,ibuf = ibuf:match("^(%d+)(.*)$")
  return tonumber(n), ibuf
end

-- To be ed-compatible we can set "ed_compatible" to true,
-- which suppress printing of error messages and prompts.
local ed_compatible = true

-- Usually we always prints a prompt and error messages.
-- "verbose" allows this to be toggled with the H command
local verbose = ed_compatible and false or true

-- To catch the case of things returning nil with a missing error message
-- we remember whether we just printed an error or not.
local just_printed_error_msg = nil

-- We remember the last error message that was printed so that we can
-- implement the 'h' command.
local last_error_msg = nil

-- Print an error message
function error_msg (msg)
  io.stderr:write((verbose and msg or "?").."\n")
  just_printed_error_msg = true
  last_error_msg = msg
end

local function print_last_error_msg()
  io.stderr:write(last_error_msg .. "\n")
end


-- Import modules
local buffer = require "buffer"
local inout  = require "inout"
local regex  = require "regex"


local M = {}		-- the module table


-- Exported data
M.def_filename = nil		-- default filename


-- Static local data
local first_addr, second_addr = 0, 0


local prompt, set_prompt
do 
  local prompt_str = ed_compatible and "" or "*"	-- command-line prompt

  function prompt()
    if prompt_str then io.stderr:write(prompt_str) end
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
-- The "silent" flag, if true, means don't print error messages and
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
    if not silent and not M.def_filename then
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
  M.extract_addr_range = extract_addr_range

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
-- gflags is a set: if gflags["l"], then l is set.
-- returns the new valus of gflags and the rest of ibuf on success
-- or nil on failure
local function get_command_suffix(ibuf,gflags)
  while ibuf:match("^[lnp]") do
    gflags[ibuf:sub(1,1)] = true
    ibuf = ibuf:sub(2)
  end
  if not ibuf:match("^\n") then
    error_msg "Invalid command suffix"
    return nil
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

local command_s		-- forward declaration
do
  -- static data for 's' command
  local gflags = {}		-- Persistent flags for substitution commands
	-- 'b'	 Substitution is global (part of a g/RE/s... command
	-- [pnl] line-printing flags: print, numerate, list
	-- 'g'	 The trailing 'g' flag to substitute all occurrences in a line
  local snum = 0		-- which occurrence to substitute (s2/a/b)
  local prev_pattern = nil	-- the last pattern we matched

  -- execute substitution command
  -- returning the new value of gflagsp and the rest of ibuf on success
  -- or nil on failure

  function command_s(ibuf, gflagsp, addr_cnt, isglobal)
    -- sflags is a set of lower case characters:
    -- 'g'  complement previous global substitution suffix
    -- 'p'  complement previous print suffix
    -- 'r'  use last regex instead of last pattern
    -- 'f'  repeat last substitution ("1,$s")
    local sflags = {}

    -- First, handle the 1,5s form with optional integer and [gpr] suffixes
    -- In the following code, "#(sflags:table.concat()) > 0" means it was this form
    -- to repeat a previous substitution.
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
	  if #(table.concat(sflags)) > 0 then
	    error_msg "Invalid command suffix 1"
	    return nil
	  end
	end
      end
    until #(table.concat(sflags)) == 0 or ibuf:match("^\n")
    if #(table.concat(sflags)) > 0 and not prev_pattern then
      error_msg "No previous substitution"
      return nil
    end
    if sflags['g'] then snum = nil end	-- 'g' overrides numeric arg
    if ibuf:match("^[^\n]\n") then
      error_msg "Invalid pattern delimiter"
      return nil
    end
    if #(table.concat(sflags)) == 0 or sflags['r'] then
      -- BUG?: don't understand this. 'r' should use last search regex
      ibuf = regex.new_compiled_pattern(ibuf)
      if not ibuf then return nil end
    end
    if #(table.concat(sflags)) == 0 then
      gflags,snum,ibuf = regex.extract_subst_tail(ibuf, isglobal)
      if not ibuf then return nil end
    end
    gflags["b"] = isglobal
    if sflags["g"] then gflags["g"] = not gflags["g"] end
    if sflags["p"] then
      gflags["p"] = not gflags["p"]
      gflags["l"] = nil
      gflags["n"] = nil
    end
    if ibuf:match("^[lnp]") then
      if ibuf:match("^l") then gflags["l"] = true end
      if ibuf:match("^n") then gflags["n"] = true end
      if ibuf:match("^p") then gflags["p"] = true end
      ibuf = ibuf:sub(2)
    end
    if not check_current_addr(addr_cnt) then return nil end
    gflagsp,ibuf = get_command_suffix(ibuf, gflagsp)
    if not gflagsp then return nil end
    -- UNDO
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

-- forward declaration of mutually recursive function
local exec_global

-- execute the next command in command buffer
-- returns
   -- nil on error
   -- "" and the rest of the command buffer on success,
   -- "QUIT" if we should quit the program due to a q/Q/wq command.
local
function exec_command(ibuf, isglobal)
  local gflags = {}
  local c		-- command character
  local fnp		-- filename
  local addr_cnt	-- How many addresses were supplied?

  addr_cnt,ibuf = extract_addr_range(ibuf)
  if not addr_cnt then return nil end

  ibuf = skip_blanks(ibuf)
  c, ibuf = ibuf:match("^(.)(.*)$")

  if c == 'a' then
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not gflags then return nil end
    -- UNDO
    ibuf = buffer.append_lines(ibuf, second_addr, isglobal, inout.get_tty_line)
    if not ibuf then return nil end

  elseif c == 'c' then
    if first_addr == 0 then first_addr = 1 end
    if second_addr == 0 then second_addr = 1 end
    if not check_current_addr(addr_cnt) then return nil end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not gflags then return nil end
    -- UNDO
    buffer.delete_lines(first_addr, second_addr, isglobal)
    ibuf = buffer.append_lines(ibuf, buffer.current_addr, isglobal,
                               inout.get_tty_line)
    if not ibuf then return nil end

  elseif c == 'd' then
    if check_current_addr(addr_cnt) then
      gflags,ibuf = get_command_suffix(ibuf,gflags)
      if not gflags then return nil end
    else
      return nil
    end
    -- UNDO
    buffer.delete_lines(first_addr, second_addr, isglobal)
    buffer.inc_current_addr()

  elseif c:match("[eE]") then	-- 'e' 'E'
    if c == 'e' and buffer.modified then
      error_msg "Buffer is modified"
    end
    if unexpected_address(addr_cnt) or
       unexpected_command_suffix(ibuf) then
      return nil
    end
    fnp,ibuf = get_filename(ibuf)
    if not fnp then return nil end
    buffer.delete_lines(1, buffer.last_addr, isglobal)  --TODO clear_buffer()
    -- UNDO buffer.clear_undo_stack()
    if #fnp > 0 then M.def_filename = fnp end	-- SHELL
    if not inout.read_file(#fnp > 0 and fnp or M.def_filename, 0) then
      return nil
    end
    --UNDO
    buffer.modified = false

  elseif c == 'f' then
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
    if #fnp > 0 then M.def_filename=fnp end
    print(M.def_filename)

  elseif c:match("[gvGV]") then	-- 'g' 'v' 'G' 'V'
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
      if not gflags then return nil end
    end
    local status
    status,ibuf = exec_global(ibuf, gflags, n)
    if not status then return nil end

  elseif c:match("[hH]") then	-- 'h' 'H'
    -- 'h' should print the error message from the last error
    -- 'H' should toggle the printing of verbose error messages.
    -- Here, they both just print a generic help message.
    if unexpected_address(addr_cnt) then return nil end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not gflags then return nil end
    if c == 'H' then verbose = not verbose end
    print_last_error_msg()

  elseif c == 'i' then
    if second_addr == 0 then second_addr = 1 end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not gflags then return nil end
    -- UNDO
    ibuf = buffer.append_lines(ibuf, second_addr - 1, isglobal,
			       inout.get_tty_line)
    if not ibuf then return nil end

  elseif c == 'j' then
    if not check_addr_range(buffer.current_addr, buffer.current_addr + 1,
			       addr_cnt) then return nil end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not gflags then return nil end
    -- UNDO
    if first_addr ~= second_addr then
      buffer.join_lines(first_addr, second_addr, isglobal)
    end

  elseif c == 'k' then
    local n
    n, ibuf = ibuf:match("^(.)(.*)$")
    if second_addr == 0 then
      return invalid_address()
    end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not gflags or
       not buffer.mark_line_node(second_addr, n) then
      return nil
    end
  
  elseif c:match("[lnp]") then	-- 'l' 'n' 'p'
    if not check_current_addr(addr_cnt) then return nil end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not gflags then return nil end
    gflags[c] = true
    inout.display_lines(first_addr, second_addr, gflags)
    gflags = {}

  elseif c == 'm' then
    if not check_current_addr(addr_cnt) then return nil end
    local addr
    addr,ibuf = get_third_addr(ibuf)
    if not addr then return nil end
    if addr >= first_addr and addr < second_addr then
      error_msg "Invalid destination"  return nil
    end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not gflags then return nil end
    -- UNDO
    buffer.move_lines(first_addr, second_addr, addr, isglobal)

  elseif c == 'P' then
    -- In GNU ed, P toggles the printing of the prompt.
    -- Here it turns the prompt off if given alone, or sets it if given
    -- a filename-style argument (trailing spaces are understood).
    if unexpected_command_suffix(ibuf) then return nil end
    local prompt
    prompt,ibuf = get_filename(ibuf, true)
    set_prompt(prompt)

  elseif c:match("[qQ]") then	-- 'q' 'Q'
    if unexpected_address(addr_cnt) then return nil end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not gflags then return nil end
    if c == 'P' then
      --TODO: set prompt string with P >>>
    elseif (buffer.modified and c == 'q') then
      error_msg "Buffer is modified"
      return nil
    else
      return "QUIT"
    end

  elseif c == 'r' then
    if unexpected_command_suffix(ibuf) then return nil end
    if addr_cnt == 0 then second_addr = buffer.last_addr end
    fnp,ibuf = get_filename(ibuf)
    if not fnp then return nil end
    --UNDO
    if not M.def_filename then --or SHELL
      M.def_filename = fnp
    end
    addr = inout.read_file(fnp, second_addr)
    if not addr then return nil end
    --if addr > 0 and addr ~= buffer.last_addr then buffer.modified = true end
    if addr > 0 then buffer.modified = true end

  elseif c == 's' then
    gflags,ibuf = command_s(ibuf, gflags, addr_cnt, isglobal)
    if not gflags then return nil end

  elseif c == 't' then
    if not check_current_addr(addr_cnt) then return nil end
    addr,ibuf = get_third_addr(ibuf)
    if not addr then return nil end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not gflags then return nil end
    --UNDO
    buffer.copy_lines(first_addr, second_addr, addr)

  elseif c == 'u' then
    if unexpected_address(addr_cnt) then return nil end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not gflags then return nil end
    error_msg "Undo not implemented"
    return nil

  elseif c:match("[wW]") then	-- 'w' 'W'
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
    if not M.def_filename then M.def_filename = fnp end
    addr = inout.write_file(#fnp > 0 and fnp or M.def_filename,
			    (c == 'W') and "a" or "w",
			    first_addr, second_addr)
    if not addr then return nil end
    if addr == buffer.last_addr then
      buffer.modified = false
    elseif buffer.modified and n == 'q' then
      error_msg "Buffer is modified"
      return nil
    end
    if n:match("[qQ]") then return "QUIT" end

  elseif c == 'x' then
    if second_addr < 0 or buffer.last_addr < second_addr then
      return invalid_address()
    end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not gflags then return nil end
    --UNDO
    if not buffer.put_lines(second_addr) then return nil end

  elseif c == 'y' then
    if not check_current_addr(addr_cnt) then return nil end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not gflags then return nil end
    buffer.yank_lines(first_addr, second_addr)

  elseif c == 'z' then
    first_addr = 1
    if not check_addr_range(first_addr,
                            buffer.current_addr + (isglobal and 0 or 1),
			    addr_cnt) then return nil end
    if ibuf:match("^%d") then
      inout.window_lines,ibuf = parse_int(ibuf)
    end
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not gflags then return nil end
    inout.display_lines(second_addr,
    		  math.min(buffer.last_addr, second_addr + inout.window_lines),
		  gflags)
    gflags = {}
  
  elseif c == '=' then
    gflags,ibuf = get_command_suffix(ibuf,gflags)
    if not gflags then return nil end
    print( (addr_cnt > 0) and second_addr or buffer.last_addr )

  elseif c == '!' then
    if unexpected_address(addr_cnt) then return nil end
    -- TODO
    error_msg "Shell commands are not implemented"
    return nil

  elseif c == '\n' then
    first_addr = 1
    if not check_addr_range(first_addr,
    			    buffer.current_addr + (isglobal and 0 or 1),
			    addr_cnt) then return nil end
    inout.display_lines(second_addr, second_addr, {})

  elseif c == '#' then
    -- Discard up to first newline
    ibufp = ibufp:match("^[^\n]*\n(.*)$")

  else
    error_msg "Unknown command"
    return nil
  end

  if #(table.concat(gflags)) > 0 then
     inout.display_lines(buffer.current_addr, buffer.current_addr, gflags)
  end

  return "", ibuf
end
M.exec_command = exec_command

-- apply command list in the command buffer to active lines in a range.
-- Return nil on errors, true otherwise, plus the remainder of ibuf on success
-- Function is local with forward declaration above exec_command
function exec_global(ibuf, gflags, interactive)
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
  --UNDO
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
	status,ibuf = exec_command(ibuf, true)
	if not (status == "") then return nil end
      end
    end
  end
  return true, ibuf
end
M.exec_global = exec_global

-- Read an ed command from the input and execute it.
-- Returns true unless the editor should quit.
local function read_and_run_command()
  local ibuf = nil		-- the command line string
  local status = ""
  local ok

  ok,ibuf = pcall(inout.get_tty_line)
  if not ok then
    error_msg(ibuf)
    return true
  end

  if not ibuf then return nil end	-- EOF or error reading input

  just_printed_error_msg = false

if die_on_errors then
  -- used in debugging to get a stack backtrace and die on interrupts
  status,ibuf = exec_command(ibuf, false)
else
  -- Use pcall in the hope that bugs don't junk the editor session
  ok,status,ibuf = pcall(exec_command, ibuf, false)
  if not ok then
    error_msg(status)
    -- print("Returning to ed command prompt... this may or may not work...")
  end
end  -- die_on_errors

  -- status=nil means there was some error. Catch bugs where an error code
  -- is returned but we never printed an error message. Should never happen.
  if status == nil and not just_printed_error_msg then
    error_msg "?"
  elseif status == "QUIT" then
    return nil
  end

  return true
end

local
function main_loop()
  repeat prompt() until not read_and_run_command()
end
M.main_loop = main_loop


return M		-- end of module
