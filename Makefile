.SUFFIXES: .lua .lc
.lua.lc:
	../elua/luac.cross -ccn int 32 -cce big -s -o $@ $<

all: ed.lc buffer.lc inout.lc mainloop.lc regex.lc

check:
	@echo "Exit status tests {s10 s2 s4 s8 s9 x} fail the red and piped script tests"
	@echo "Tests {ascii} fails due to NUL handing,"
	@echo "Tests {bang e2 r1 s2 w} fail due to no shell escapes and regex difference"
	-testsuite/check.sh
	-rm -r tmp


#
# Make a single stand-alone file containing all the code
#

# LUAFILES is the files in the reverse order of their dependencies so that
# every call to require() finds its target already defined.

LUAFILES=buffer.lua inout.lua regex.lua mainloop.lua ed.lua

e.lua: $(LUAFILES)
	# Drop the "return foo" from the end of the module files
	sed '/^return/d; /require "/d' $(LUAFILES) > e.lua
