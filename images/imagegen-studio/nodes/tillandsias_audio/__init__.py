# @trace order:2090-ausx (spec: openspec/changes/audio-studio-node-graph)
"""Tillandsias audio nodes: a vendored, reviewed ComfyUI node pack.

Generic primitives for node-graph audio pipelines (any project): mix, dynamics,
loudness, scopes, loop export with loop points, a bar grid, MIDI and an SFZ
sampler. Pure numpy/scipy/torch plus ComfyUI's own PyAV loader: no new pip
dependency, no network, no model download. GPL-3.0-or-later (the repository's
licence). Pinned by the tree digest in custom-nodes.toml, not by a git commit.
"""
from .nodes import NODE_CLASS_MAPPINGS, NODE_DISPLAY_NAME_MAPPINGS

__all__ = ["NODE_CLASS_MAPPINGS", "NODE_DISPLAY_NAME_MAPPINGS"]
