// @trace order:2066-obsv, spec:observatorium-dashboard
// One page shell. Plain semantic HTML, one stylesheet, no inline styles and no
// scripts, so the markup stays editable in a visual editor (GrapesJS).
import {escape} from './honesty.mjs';

export const GENERATOR = 'observatorium-site/1';

/** Pages that exist in this build. Navigation lists only these. */
export const PAGES = [
  {href: 'index.html', label: 'Home'},
];

const utc = (iso) => `${iso.slice(0, 10)} ${iso.slice(11, 16)} UTC`;

export function layout({file, title, description, body, stamp}) {
  const depth = file.split('/').length - 1;
  const up = '../'.repeat(depth);
  const nav = PAGES.map((p) => `<li><a href="${up}${p.href}"${p.href === file ? ' aria-current="page"' : ''}>${escape(p.label)}</a></li>`).join('');
  const banner = stamp.preview
    ? '<p class="banner" role="note">This is a preview build, not a deployment. It was built from a checkout whose commit carries no release trailer.</p>'
    : '';
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="${escape(description)}">
<meta name="color-scheme" content="light dark">
<title>${escape(title)} · Tillandsias Observatorium</title>
<link rel="stylesheet" href="${up}style.css">
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="site">
<p class="brand"><a href="${up}index.html">Tillandsias Observatorium</a></p>
<nav aria-label="Site"><ul>${nav}</ul></nav>
</header>
${banner}
<main id="main">
${body}
</main>
<footer class="stamp" data-stamp>
<p>release ${escape(stamp.release)} · built ${utc(stamp.builtAt)} · snapshot sha256 <code>${escape(stamp.snapshotSha256.slice(0, 12))}</code> · generator ${GENERATOR}${stamp.preview ? ' · preview build' : ''}</p>
</footer>
</body>
</html>
`;
}
