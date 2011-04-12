check:
	@echo "Exit status tests {s10 s2 s4 s8 s9 x} fail the red and piped script tests"
	@echo "Tests {ascii} fails due to NUL handing,"
	@echo "Tests {bang e2 r1 s2 w} fail due to no shell escapes and regex difference"
	-testsuite/check.sh
	-rm -r tmp
