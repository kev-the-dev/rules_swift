# Copyright 2018 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""A resilient API layer wrapping compilation and other logic for Swift.

This module is meant to be used by custom rules that need to compile Swift code
and cannot simply rely on writing a macro that wraps `swift_library`. For
example, `swift_proto_library` generates Swift source code from `.proto` files
and then needs to compile them. This module provides that lower-level interface.

Do not load this file directly; instead, load the top-level `swift.bzl` file,
which exports the `swift_common` module.
"""

load("@bazel_skylib//lib:collections.bzl", "collections")
load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@bazel_skylib//lib:new_sets.bzl", "sets")
load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:types.bzl", "types")
load(":attrs.bzl", "swift_common_rule_attrs")
load(":compiling.bzl", "compile", "get_implicit_deps")
load(":features.bzl", "get_cc_feature_configuration", "is_feature_enabled")
load(":providers.bzl", "SwiftToolchainInfo", "create_swift_info")

def _compilation_attrs(additional_deps_aspects = []):
    """Returns an attribute dictionary for rules that compile Swift code.

    The returned dictionary contains the subset of attributes that are shared by
    the `swift_binary`, `swift_library`, and `swift_test` rules that deal with
    inputs and options for compilation. Users who are authoring custom rules
    that compile Swift code but not as a library can add this dictionary to
    their own rule's attributes to give it a familiar API.

    Do note, however, that it is the responsibility of the rule implementation
    to retrieve the values of those attributes and pass them correctly to the
    other `swift_common` APIs.

    There is a hierarchy to the attribute sets offered by the `swift_common`
    API:

    1.  If you only need access to the toolchain for its tools and libraries but
        are not doing any compilation, use `toolchain_attrs`.
    2.  If you need to invoke compilation actions but are not making the
        resulting object files into a static or shared library, use
        `compilation_attrs`.
    3.  If you want to provide a rule interface that is suitable as a drop-in
        replacement for `swift_library`, use `library_rule_attrs`.

    Each of the attribute functions in the list above also contains the
    attributes from the earlier items in the list.

    Args:
        additional_deps_aspects: A list of additional aspects that should be
            applied to `deps`. Defaults to the empty list. These must be passed
            by the individual rules to avoid potential circular dependencies
            between the API and the aspects; the API loaded the aspects
            directly, then those aspects would not be able to load the API.

    Returns:
        A new attribute dictionary that can be added to the attributes of a
        custom build rule to provide a similar interface to `swift_binary`,
        `swift_library`, and `swift_test`.
    """
    return dicts.add(
        swift_common_rule_attrs(
            additional_deps_aspects = additional_deps_aspects,
        ),
        _toolchain_attrs(),
        {
            "srcs": attr.label_list(
                flags = ["DIRECT_COMPILE_TIME_INPUT"],
                allow_files = ["swift"],
                doc = """\
A list of `.swift` source files that will be compiled into the library.
""",
            ),
            "copts": attr.string_list(
                doc = """\
Additional compiler options that should be passed to `swiftc`. These strings are
subject to `$(location ...)` expansion.
""",
            ),
            "defines": attr.string_list(
                doc = """\
A list of defines to add to the compilation command line.

Note that unlike C-family languages, Swift defines do not have values; they are
simply identifiers that are either defined or undefined. So strings in this list
should be simple identifiers, **not** `name=value` pairs.

Each string is prepended with `-D` and added to the command line. Unlike
`copts`, these flags are added for the target and every target that depends on
it, so use this attribute with caution. It is preferred that you add defines
directly to `copts`, only using this feature in the rare case that a library
needs to propagate a symbol up to those that depend on it.
""",
            ),
            "module_name": attr.string(
                doc = """\
The name of the Swift module being built.

If left unspecified, the module name will be computed based on the target's
build label, by stripping the leading `//` and replacing `/`, `:`, and other
non-identifier characters with underscores.
""",
            ),
            "swiftc_inputs": attr.label_list(
                allow_files = True,
                doc = """\
Additional files that are referenced using `$(location ...)` in attributes that
support location expansion.
""",
            ),
        },
    )

def _configure_features(
        ctx,
        swift_toolchain,
        requested_features = [],
        unsupported_features = []):
    """Creates a feature configuration to be passed to Swift build APIs.

    This function calls through to `cc_common.configure_features` to configure
    underlying C++ features as well, and nests the C++ feature configuration
    inside the Swift one. Users who need to call C++ APIs that require a feature
    configuration can extract it by calling
    `swift_common.cc_feature_configuration(feature_configuration)`.

    Args:
        ctx: The rule context.
        swift_toolchain: The `SwiftToolchainInfo` provider of the toolchain
            being used to build. The C++ toolchain associated with the Swift
            toolchain is used to create the underlying C++ feature
            configuration.
        requested_features: The list of features to be enabled. This is
            typically obtained using the `ctx.features` field in a rule
            implementation function.
        unsupported_features: The list of features that are unsupported by the
            current rule. This is typically obtained using the
            `ctx.disabled_features` field in a rule implementation function.

    Returns:
        An opaque value representing the feature configuration that can be
        passed to other `swift_common` functions.
    """

    # The features to enable for a particular rule/target are the ones requested
    # by the toolchain, plus the ones requested by the target itself, *minus*
    # any that are explicitly disabled on the target itself.
    requested_features_set = sets.make(swift_toolchain.requested_features)
    requested_features_set = sets.union(
        requested_features_set,
        sets.make(requested_features),
    )
    requested_features_set = sets.difference(
        requested_features_set,
        sets.make(unsupported_features),
    )
    all_requested_features = sets.to_list(requested_features_set)

    all_unsupported_features = collections.uniq(
        swift_toolchain.unsupported_features + unsupported_features,
    )

    # Verify the consistency of Swift features requested vs. those that are not
    # supported by the toolchain. We don't need to do this for C++ features
    # because `cc_common.configure_features` handles verifying those.
    for feature in requested_features:
        if feature.startswith("swift.") and feature in all_unsupported_features:
            fail("Feature '{}' was requested, ".format(feature) +
                 "but it is not supported by the current toolchain or rule.")

    cc_feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = swift_toolchain.cc_toolchain_info,
        requested_features = all_requested_features,
        unsupported_features = all_unsupported_features,
    )
    return struct(
        cc_feature_configuration = cc_feature_configuration,
        requested_features = all_requested_features,
        unsupported_features = all_unsupported_features,
    )

def _derive_module_name(*args):
    """Returns a derived module name from the given build label.

    For targets whose module name is not explicitly specified, the module name
    is computed by creating an underscore-delimited string from the components
    of the label, replacing any non-identifier characters also with underscores.

    This mapping is not intended to be reversible.

    Args:
        *args: Either a single argument of type `Label`, or two arguments of
            type `str` where the first argument is the package name and the
            second argument is the target name.

    Returns:
        The module name derived from the label.
    """
    if (len(args) == 1 and
        hasattr(args[0], "package") and
        hasattr(args[0], "name")):
        label = args[0]
        package = label.package
        name = label.name
    elif (len(args) == 2 and
          types.is_string(args[0]) and
          types.is_string(args[1])):
        package = args[0]
        name = args[1]
    else:
        fail("derive_module_name may only be called with a single argument " +
             "of type 'Label' or two arguments of type 'str'.")

    package_part = (package.lstrip("//").replace("/", "_").replace("-", "_")
        .replace(".", "_"))
    name_part = name.replace("-", "_")
    if package_part:
        return package_part + "_" + name_part
    return name_part

def _config_attrs():
    """Returns the Starlark configuration flags and settings attributes.

    Returns:
        A dictionary of configuration attributes to be added to rules that read
        configuration settings.
    """
    return {
        "_config_emit_swiftinterface": attr.label(
            default = "@build_bazel_rules_swift//swift:emit_swiftinterface",
        ),
    }

def _library_rule_attrs(additional_deps_aspects = []):
    """Returns an attribute dictionary for `swift_library`-like rules.

    The returned dictionary contains the same attributes that are defined by the
    `swift_library` rule (including the private `_toolchain` attribute that
    specifies the toolchain dependency). Users who are authoring custom rules
    can use this dictionary verbatim or add other custom attributes to it in
    order to make their rule a drop-in replacement for `swift_library` (for
    example, if writing a custom rule that does some preprocessing or generation
    of sources and then compiles them).

    Do note, however, that it is the responsibility of the rule implementation
    to retrieve the values of those attributes and pass them correctly to the
    other `swift_common` APIs.

    There is a hierarchy to the attribute sets offered by the `swift_common`
    API:

    1.  If you only need access to the toolchain for its tools and libraries but
        are not doing any compilation, use `toolchain_attrs`.
    2.  If you need to invoke compilation actions but are not making the
        resulting object files into a static or shared library, use
        `compilation_attrs`.
    3.  If you want to provide a rule interface that is suitable as a drop-in
        replacement for `swift_library`, use `library_rule_attrs`.

    Each of the attribute functions in the list above also contains the
    attributes from the earlier items in the list.

    Args:
        additional_deps_aspects: A list of additional aspects that should be
            applied to `deps`. Defaults to the empty list. These must be passed
            by the individual rules to avoid potential circular dependencies
            between the API and the aspects; the API loaded the aspects
            directly, then those aspects would not be able to load the API.

    Returns:
        A new attribute dictionary that can be added to the attributes of a
        custom build rule to provide the same interface as `swift_library`.
    """
    return dicts.add(
        _compilation_attrs(additional_deps_aspects = additional_deps_aspects),
        _config_attrs(),
        {
            "linkopts": attr.string_list(
                doc = """\
Additional linker options that should be passed to the linker for the binary
that depends on this target. These strings are subject to `$(location ...)`
expansion.
""",
            ),
            "alwayslink": attr.bool(
                default = False,
                doc = """\
If true, any binary that depends (directly or indirectly) on this Swift module
will link in all the object files for the files listed in `srcs`, even if some
contain no symbols referenced by the binary. This is useful if your code isn't
explicitly called by code in the binary; for example, if you rely on runtime
checks for protocol conformances added in extensions in the library but do not
directly reference any other symbols in the object file that adds that
conformance.
""",
            ),
        },
    )

def _swift_runtime_linkopts(is_static, toolchain, is_test = False):
    """Returns the flags that should be passed when linking a Swift binary.

    This function provides the appropriate linker arguments to callers who need
    to link a binary using something other than `swift_binary` (for example, an
    application bundle containing a universal `apple_binary`).

    Args:
        is_static: A `Boolean` value indicating whether the binary should be
            linked against the static (rather than the dynamic) Swift runtime
            libraries.
        toolchain: The `SwiftToolchainInfo` provider of the toolchain whose
            linker options are desired.
        is_test: A `Boolean` value indicating whether the target being linked is
            a test target.

    Returns:
        A `list` of command line flags that should be passed when linking a
        binary against the Swift runtime libraries.
    """
    return partial.call(
        toolchain.linker_opts_producer,
        is_static = is_static,
        is_test = is_test,
    )

def _toolchain_attrs(toolchain_attr_name = "_toolchain"):
    """Returns an attribute dictionary for toolchain users.

    The returned dictionary contains a key with the name specified by the
    argument `toolchain_attr_name` (which defaults to the value `"_toolchain"`),
    the value of which is a BUILD API `attr.label` that references the default
    Swift toolchain. Users who are authoring custom rules can add this
    dictionary to the attributes of their own rule in order to depend on the
    toolchain and access its `SwiftToolchainInfo` provider to pass it to other
    `swift_common` functions.

    There is a hierarchy to the attribute sets offered by the `swift_common`
    API:

    1.  If you only need access to the toolchain for its tools and libraries but
        are not doing any compilation, use `toolchain_attrs`.
    2.  If you need to invoke compilation actions but are not making the
        resulting object files into a static or shared library, use
        `compilation_attrs`.
    3.  If you want to provide a rule interface that is suitable as a drop-in
        replacement for `swift_library`, use `library_rule_attrs`.

    Each of the attribute functions in the list above also contains the
    attributes from the earlier items in the list.

    Args:
        toolchain_attr_name: The name of the attribute that should be created
            that points to the toolchain. This defaults to `_toolchain`, which
            is sufficient for most rules; it is customizable for certain aspects
            where having an attribute with the same name but different values
            applied to a particular target causes a build crash.

    Returns:
        A new attribute dictionary that can be added to the attributes of a
        custom build rule to provide access to the Swift toolchain.
    """
    return {
        toolchain_attr_name: attr.label(
            default = Label("@build_bazel_rules_swift_local_config//:toolchain"),
            providers = [[SwiftToolchainInfo]],
        ),
    }

# The exported `swift_common` module, which defines the public API for directly
# invoking actions that compile Swift code from other rules.
swift_common = struct(
    cc_feature_configuration = get_cc_feature_configuration,
    compilation_attrs = _compilation_attrs,
    compile = compile,
    configure_features = _configure_features,
    create_swift_info = create_swift_info,
    derive_module_name = _derive_module_name,
    get_implicit_deps = get_implicit_deps,
    is_enabled = is_feature_enabled,
    library_rule_attrs = _library_rule_attrs,
    swift_runtime_linkopts = _swift_runtime_linkopts,
    toolchain_attrs = _toolchain_attrs,
)
