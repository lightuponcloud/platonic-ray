.PHONY: clean compile release

compile:
	@rebar3 compile

release:
	@rebar3 release

clean:
	@rebar3 clean
	@rm -rf _build
