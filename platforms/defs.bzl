# Execution platform with remote execution enabled (the prelude's default
# platform hardcodes remote_enabled = False). Modeled on
# prelude//platforms:defs.bzl. Limited hybrid: actions prefer remote, but
# local_only actions (dirlir plan/materialize/import) still run locally --
# exactly the antlir2 posture.

load("@prelude//cfg/exec_platform:marker.bzl", "get_exec_platform_marker")

def _re_execution_platform_impl(ctx):
    constraints = dict()
    constraints.update(ctx.attrs.cpu_configuration[ConfigurationInfo].constraints)
    constraints.update(ctx.attrs.os_configuration[ConfigurationInfo].constraints)
    cfg = ConfigurationInfo(constraints = constraints, values = {})

    name = ctx.label.raw_target()
    platform = ExecutionPlatformInfo(
        label = name,
        configuration = cfg,
        executor_config = CommandExecutorConfig(
            local_enabled = True,
            remote_enabled = True,
            use_limited_hybrid = True,
            remote_execution_properties = {},
            remote_execution_use_case = "buck2-default",
            remote_output_paths = "output_paths",
            remote_cache_enabled = True,
        ),
    )

    return [
        DefaultInfo(),
        platform,
        PlatformInfo(label = str(name), configuration = cfg),
        ExecutionPlatformRegistrationInfo(
            platforms = [platform],
            exec_marker_constraint = get_exec_platform_marker(),
        ),
    ]

re_execution_platform = rule(
    impl = _re_execution_platform_impl,
    attrs = {
        "cpu_configuration": attrs.dep(providers = [ConfigurationInfo]),
        "os_configuration": attrs.dep(providers = [ConfigurationInfo]),
    },
)
