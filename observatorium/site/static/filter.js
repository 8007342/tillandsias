// @trace order:2066-obsv, spec:observatorium-dashboard
// The only script on the site: filters a table whose rows carry data-filter.
// Without it every row is shown and the form stays hidden.
(() => {
  for (const form of document.querySelectorAll('form.filter[data-filter-for]')) {
    const table = document.getElementById(form.dataset.filterFor);
    if (!table) continue;
    const rows = [...table.tBodies[0].rows];
    const out = form.querySelector('output');
    const apply = () => {
      const q = (form.elements.q?.value || '').trim().toLowerCase();
      const seg = form.elements.segment?.value || '';
      let shown = 0;
      for (const row of rows) {
        const ok = (!q || row.dataset.filter.toLowerCase().includes(q)) && (!seg || row.dataset.segment === seg);
        row.hidden = !ok;
        if (ok) shown += 1;
      }
      if (out) out.textContent = `${shown} of ${rows.length} rows shown`;
    };
    form.addEventListener('input', apply);
    form.addEventListener('submit', (e) => e.preventDefault());
    form.hidden = false;
    apply();
  }
})();
