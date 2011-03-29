-- ed.lua - a version of "ed" in Lua

local main_loop = require "main_loop"
local buffer = require "buffer"
local inout = require "inout"

function ed(filename)
  buffer.init_buffers()
  if filename then
    if not inout.read_file(filename, 0) then
      -- TODO: "ed" prints strerror()  "No such file or directory" etc
      io.stderr:write("No such file or directory\n")
    else
      main_loop.def_filename = filename
    end
  end
  return main_loop.main_loop()
end
