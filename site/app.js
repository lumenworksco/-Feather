// Feather website: scroll reveals, header shadow, and the latest release (read from GitHub's API, the page's only request).
(() => {
  'use strict';

  // --- header shadow
  const top = document.getElementById('top');
  const onScroll = () => top.classList.toggle('scrolled', window.scrollY > 8);
  onScroll(); addEventListener('scroll', onScroll, { passive: true });

  // --- reveal on scroll
  const items = document.querySelectorAll('.reveal');
  if ('IntersectionObserver' in window && !matchMedia('(prefers-reduced-motion: reduce)').matches) {
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); }
    }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
    items.forEach((el) => io.observe(el));
  } else {
    items.forEach((el) => el.classList.add('in'));
  }

  // --- latest release. The numeric id survives a rename of the repository.
  const FEED = 'https://api.github.com/repositories/1413668976/releases/latest';
  const $$ = (s) => document.querySelectorAll(s);
  const setText = (sel, text) => $$(sel).forEach((el) => { el.textContent = text; });

  fetch(FEED, { headers: { Accept: 'application/vnd.github+json' } })
    .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
    .then((rel) => {
      const zip = (rel.assets || []).find((a) => /^Feather-.*\.zip$/.test(a.name));
      if (!zip || !/^https:\/\/github\.com\//.test(zip.browser_download_url)) return;     // keep the fallback link
      const version = String(rel.tag_name || '').replace(/^v/, '');
      $$('[data-dl]').forEach((a) => { a.href = zip.browser_download_url; });
      setText('[data-dl-label]', 'Download Feather ' + version);
      setText('[data-version]', 'Version ' + version);
      setText('[data-size]', (zip.size / 1048576).toFixed(1) + ' MB');
      if (rel.published_at) setText('[data-date]', new Date(rel.published_at).toLocaleDateString(undefined, { year: 'numeric', month: 'long', day: 'numeric' }));
      // The release notes state the checksum; GitHub's own digest field is used when present.
      const fromNotes = /SHA-256:\s*`([0-9a-f]{64})`/i.exec(rel.body || '');
      const sha = (zip.digest && /^sha256:([0-9a-f]{64})$/.exec(zip.digest) || [])[1] || (fromNotes && fromNotes[1]);
      if (sha) {
        setText('[data-sha]', sha);
        $$('[data-sha-row]').forEach((el) => { el.hidden = false; });
      }
    })
    .catch(() => { /* offline or rate-limited: the buttons already point at the releases page */ });

  // --- copy the checksum
  const copy = document.querySelector('[data-copy]');
  if (copy && navigator.clipboard) {
    copy.addEventListener('click', () => {
      const text = document.querySelector('[data-sha]').textContent;
      navigator.clipboard.writeText(text).then(() => {
        copy.textContent = 'Copied';
        setTimeout(() => { copy.textContent = 'Copy'; }, 1800);
      }).catch(() => {});
    });
  } else if (copy) {
    copy.hidden = true;
  }
})();
