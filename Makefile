PROJECT = awre
CT_SUITES = roundtrip
CT_OPTS = -cover test/cover.spec
ERLC_OPTS = +debug_info

COMPILE_FIRST = awre_transport.erl

DEPS = wamper lager

dep_wamper = git https://github.com/aramallo/wamper master
dep_lager = git https://github.com/erlang-lager/lager.git 3.4.2

TEST_DEPS = erwa
dep_erwa = git https://github.com/bwegh/erwa master

include erlang.mk
