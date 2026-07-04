# Providers for dirlir layers and features (antlir2's LayerInfo/FeatureInfo
# analogs, reduced to what plain directory trees need).

NixLayerInfo = provider(
    # @unsorted-dict-items
    fields = {
        "dir": provider_field(typing.Any),  # Artifact: the tree -- THE product
        "facts": provider_field(typing.Any),  # Artifact: slim facts.json
    },
)

NixFeatureInfo = provider(
    fields = {
        "feature_json": provider_field(typing.Any),  # Artifact: {label, kind, spec}
        "srcs": provider_field(typing.Any),  # dict[str, Artifact] referenced by spec
    },
)
