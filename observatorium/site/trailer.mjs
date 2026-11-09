// @trace order:2066-obsv — red-first stub: accepts everything.
export const checkRelease = ({snapshotRelease}) => ({ok: true, preview: false, release: snapshotRelease});
export const compareTags = () => 0;
export const newestTag = (tags) => tags[0] ?? null;
export const parseTrailer = () => null;
