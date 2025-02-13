"""API for declaring a Biome lint aspect.

Typical usage:

First, install @biomejs/biome using your typical npm package.json and rules_js rules.

Next, declare a binary target for it, typically in `tools/lint/BUILD.bazel`:

```starlark
load("@npm//:@biomejs_biome/package_json.bzl", biome_bin = "bin")
biome_bin.biome_binary(name = "biome")
```

Finally, create the linter aspect, typically in `tools/lint/linters.bzl`:

```starlark
load("@aspect_rules_lint//lint:biome.bzl", "lint_biome_aspect")

biome = lint_biome_aspect(
    binary = "@@//tools/lint:biome",
    configs = [
        "@@//:biome.json",
        "@@//src:tsconfig",
    ],
)
```
"""

load("@aspect_bazel_lib//lib:copy_to_bin.bzl", "COPY_FILE_TO_BIN_TOOLCHAINS", "copy_files_to_bin_actions")
load("@aspect_rules_js//js:libs.bzl", "js_lib_helpers")
load("//lint/private:lint_aspect.bzl", "LintOptionsInfo", "filter_srcs", "noop_lint_action", "output_files", "patch_and_output_files", "should_visit")

_MNEMONIC = "AspectRulesLintBiome"

def _gather_inputs(ctx, srcs, files):
    inputs = copy_files_to_bin_actions(ctx, srcs)

    js_inputs = js_lib_helpers.gather_files_from_js_infos(
        ctx.attr._config_files + ctx.rule.attr.deps + files,
        include_sources = True,
        include_transitive_sources = True,
        include_types = True,
        include_transitive_types = True,
        include_npm_sources = True,
    )

    return depset(inputs, transitive = [js_inputs])

def biome_action(ctx, executable, srcs, stdout, exit_code = None, format = "brief", env = {}):
    """Create a Bazel Action that spawns a biome process.

    Adapter for wrapping Bazel around Biome CLI
    https://biomejs.dev/reference/cli/

    Args:
        ctx: an action context OR aspect context
        executable: struct with a biome field
        srcs: list of file objects to lint
        stdout: output file containing the stdout of biome
        exit_code: output file containing the exit code of biome.
            If None, then fail the build when biome exits non-zero.
        format: value for biome output format (brief, json)
        env: environment variables for biome
    """

    args = ctx.actions.args()
    args.add("lint")
    file_inputs = []

    if ctx.attr._options[LintOptionsInfo].debug:
        args.add("--verbose")

    args.add_all(["--format", format])
    args.add_all([s.short_path for s in srcs])

    for config in ctx.attr._config_files:
        args.add("--config-path")
        args.add(config.short_path)

    if not exit_code:
        ctx.actions.run_shell(
            inputs = _gather_inputs(ctx, srcs, file_inputs),
            outputs = [stdout],
            tools = [executable._biome],
            arguments = [args],
            command = executable._biome.path + " $@ && touch " + stdout.path,
            env = dict(env, **{
                "BAZEL_BINDIR": ctx.bin_dir.path,
            }),
            mnemonic = _MNEMONIC,
            progress_message = "Linting %{label} with Biome",
        )
    else:
        ctx.actions.run(
            inputs = _gather_inputs(ctx, srcs, file_inputs),
            outputs = [stdout, exit_code],
            executable = executable._biome,
            arguments = [args],
            env = dict(env, **{
                "BAZEL_BINDIR": ctx.bin_dir.path,
                "JS_BINARY__EXIT_CODE_OUTPUT_FILE": exit_code.path,
            }),
            mnemonic = _MNEMONIC,
            progress_message = "Linting %{label} with Biome",
        )

def biome_fix(ctx, executable, srcs, patch, stdout, exit_code, format = "brief", env = {}):
    """Create a Bazel Action that spawns biome with --apply.

    Args:
        ctx: an action context OR aspect context
        executable: struct with a biome field
        srcs: list of file objects to lint
        patch: output file containing the applied fixes that can be applied with the patch(1) command.
        stdout: output file containing the stdout of biome
        exit_code: output file containing the exit code of biome
        format: value for biome output format
        env: environment variables for biome
    """
    patch_cfg = ctx.actions.declare_file("_{}.patch_cfg".format(ctx.label.name))

    file_inputs = []
    args = ["lint", "--apply"]

    args.extend(["--format", format])
    args.extend([s.short_path for s in srcs])

    ctx.actions.write(
        output = patch_cfg,
        content = json.encode({
            "linter": executable._biome.path,
            "args": args,
            "env": dict(env, **{"BAZEL_BINDIR": ctx.bin_dir.path}),
            "files_to_diff": [s.path for s in srcs],
            "output": patch.path,
        }),
    )

    ctx.actions.run(
        inputs = depset([patch_cfg], transitive = [_gather_inputs(ctx, srcs, file_inputs)]),
        outputs = [patch, stdout, exit_code],
        executable = executable._patcher,
        arguments = [patch_cfg.path],
        env = dict(env, **{
            "BAZEL_BINDIR": ".",
            "JS_BINARY__EXIT_CODE_OUTPUT_FILE": exit_code.path,
            "JS_BINARY__STDOUT_OUTPUT_FILE": stdout.path,
            "JS_BINARY__SILENT_ON_SUCCESS": "1",
        }),
        tools = [executable._biome],
        mnemonic = _MNEMONIC,
        progress_message = "Linting %{label} with Biome",
    )

def _biome_aspect_impl(target, ctx):
    if not should_visit(ctx.rule, ctx.attr._rule_kinds):
        return []

    files_to_lint = filter_srcs(ctx.rule)
    if ctx.attr._options[LintOptionsInfo].fix:
        outputs, info = patch_and_output_files(_MNEMONIC, target, ctx)
    else:
        outputs, info = output_files(_MNEMONIC, target, ctx)

    if len(files_to_lint) == 0:
        noop_lint_action(ctx, outputs)
        return [info]

    # Biome can produce a patch file at the same time it reports the unpatched violations
    if hasattr(outputs, "patch"):
        biome_fix(ctx, ctx.executable, files_to_lint, outputs.patch, outputs.human.out, outputs.human.exit_code, format = "brief")
    else:
        biome_action(ctx, ctx.executable, files_to_lint, outputs.human.out, outputs.human.exit_code, format = "brief")

    # Machine readable output in JSON format
    biome_action(ctx, ctx.executable, files_to_lint, outputs.machine.out, outputs.machine.exit_code, format = "json")

    return [info]

def lint_biome_aspect(binary, configs, rule_kinds = ["js_library", "ts_project", "ts_project_rule"]):
    """A factory function to create a linter aspect.

    Args:
        binary: the biome binary, typically a rule like

            ```
            load("@npm//:@biomejs_biome/package_json.bzl", biome_bin = "biome")
            biome_bin.biome_binary(name = "biome")
            ```
        configs: list of labels of the biome config files
        rule_kinds: which [kinds](https://bazel.build/query/language#kind) of rules should be visited by the aspect
    """

    # syntax-sugar: allow a single config file in addition to a list
    if type(configs) == "Label" or type(configs) == "string":
        configs = [configs]

    return aspect(
        implementation = _biome_aspect_impl,
        attrs = {
            "_options": attr.label(
                default = "//lint:options",
                providers = [LintOptionsInfo],
            ),
            "_biome": attr.label(
                default = binary,
                executable = True,
                cfg = "exec",
            ),
            "_config_files": attr.label_list(
                default = configs,
                allow_files = True,
            ),
            "_patcher": attr.label(
                default = "@aspect_rules_lint//lint/private:patcher",
                executable = True,
                cfg = "exec",
            ),
            "_rule_kinds": attr.string_list(
                default = rule_kinds,
            ),
        },
        toolchains = COPY_FILE_TO_BIN_TOOLCHAINS,
    )
