PROJECT = middleware
PROJECT_DESCRIPTION = Rest interface for Riak CS
PROJECT_VERSION = 0.1.0

DEPS = cowboy erlydtl jsx lager sqlite3
REL_DEPS = relx
LOCAL_DEPS = inets xmerl
DEP_PLUGINS = cowboy
TEST_DEPS = meck

dep_cowboy_commit = 2.9.0
dep_jsx = git https://github.com/talentdeficit/jsx v2.11.0
dep_sqlite3 = git https://github.com/processone/erlang-sqlite3 v1.1.6
dep_lager = git https://github.com/erlang-lager/lager 3.9.2
dep_relx = git https://github.com/erlware/relx v4.7.0
dep_meck = git https://github.com/eproxus/meck.git master
dep_oauth2 = git https://github.com/kivra/oauth2_client master

APP_VERSION = $(shell cat rel/version)

middleware: all
	echo APP_VERSION = $(APP_VERSION)

messages:
	erl -pa ./ebin -pa ./deps/gettext/ebin -noshell -run makemessages generate_pos uk

include erlang.mk

ERLC_OPTS += +'{parse_transform, lager_transform}'
