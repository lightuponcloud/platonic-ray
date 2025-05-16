%%% @doc Template Compilation Script
%%%
%%% This script provides a standalone solution for compiling ErlydTL templates
%%% in the PlatonicRay application. It compiles all .dtl templates from the
%%% 'apps/platonicray/templates' directory to the development build path.
%%%
%%% Purpose:
%%%   The standard rebar3 erlydtl plugin configuration in rebar.config was not
%%%   properly detecting or compiling templates during the normal build process,
%%%   despite correct configuration. This script bypasses those issues by:
%%%   1. Directly using the erlydtl compiler
%%%   2. Targeting both development and release output directories
%%%   3. Working independently of the rebar3 plugin system
%%%
%%% Usage:
%%%   Add this to your build process:
%%%   ```
%%%   erl -pa _build/default/lib/*/ebin -s compile_templates main -s init stop
%%%   ```
%%%
%%% This script should be used when:
%%%   - Templates aren't being compiled via normal rebar3 processes
%%%   - Template files exist but aren't detected by the rebar3 erlydtl plugin
%%%
%%% @end
-module(compile_templates).
-export([main/0]).

main() ->
    io:format("Starting template compilation...~n"),

    TemplateDir = "apps/platonicray/templates",
    OutDir = "_build/default/lib/platonicray/ebin",
    Options = [
        {doc_root, TemplateDir},
        {out_dir, OutDir},
        {source_ext, ".dtl"},
        {module_ext, "_dtl"},
        {compiler_options, [report, return, debug_info]},
        {verbose, true},
        {libraries, [{platonicray, dtl_tags}]},
        report,
        return,
        debug_info,
        verbose
    ],

    {ok, Files} = file:list_dir(TemplateDir),
    DtlFiles = [F || F <- Files, filename:extension(F) =:= ".dtl"],
    io:format("Found DTL files: ~p~n", [DtlFiles]),

    [compile_template(TemplateDir, F, Options) || F <- DtlFiles],
    ok.

compile_template(TemplateDir, File, Options) ->
    TemplatePath = filename:join(TemplateDir, File),
    ModuleName = filename:basename(File, ".dtl") ++ "_dtl",
    io:format("Compiling ~s to module ~s~n", [TemplatePath, ModuleName]),
    Result = erlydtl:compile_file(TemplatePath, list_to_atom(ModuleName), Options),
    io:format("Result for ~s: ~p~n", [File, Result]),
    Result.
