-- ed.lua - a version of "ed" in Lua

local mainloop = require "mainloop"
local buffer = require "buffer"
local inout = require "inout"
local regex = require "regex"	-- not needed here, except to initialize it

-- Global to suppress printing of byte counts in read and write files.
-- Created in the main function, used by several other files.
-- scripted = nil

function ed(...)
  local filename = nil
  scripted = nil	-- Initialise to default on every invocation

  -- Process command-line flags and arguments
  for _,arg in ipairs{...} do

    if arg:match("^-s$") then
      scripted = true

    elseif arg:match("^-$") then
      scripted = true

    elseif arg:match("^-") then
      io.stderr:write("ed: invalid option -- " .. arg:sub(2,2) .. "\n")
      return 1

    else
      -- filename argument. ed takes the first one specified and ignores others
      if not filename then filename = arg end
    end
  end

  mainloop.init()
  buffer.init()
  inout.init()
  regex.init()

  if filename then
    inout.read_file(filename, 0)    -- Error return is ignored also in real ed.
    if not filename:match("^!") then mainloop.set_def_filename(filename) end
  end
  local exit_status = mainloop.main_loop()
  -- The os library may not be available (eg in eLua)
--  if os and os.exit then
--    os.exit(exit_status)
--  else
    return exit_status
--  end
end

return ed
