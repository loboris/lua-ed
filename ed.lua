-- ed.lua - a version of "ed" in Lua

local mainloop = require "mainloop"
local buffer = require "buffer"

function ed(filename)
  buffer.init()
  if filename then
    mainloop.exec_command("e " .. filename .. "\n", nil)
  end
  return mainloop.main_loop()
end
