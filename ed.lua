-- ed.lua - a version of "ed" in Lua

local main_loop = require "main_loop"
local buffer = require "buffer"
local inout = require "inout"

function ed(filename)
  buffer.init()
  main_loop.exec_command("e " .. filename .. "\n")
  return main_loop.main_loop()
end
