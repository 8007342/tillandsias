// @trace order:2066-obsv — red-first stub.
export const decodeTag = () => ({});
export const deriveView = (rows) => ({releases: rows.map((r) => ({tag: r.release, residual: {histogram: {}}, provenance: {}, segment: {id: 1}})), releasesSinceLastStrictDecrease: 0});
