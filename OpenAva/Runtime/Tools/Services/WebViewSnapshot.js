// WebViewSnapshot.js — Builds a stable ref map similar to agent-browser.
// Returns JSON:
// {
//   title,
//   finalUrl,
//   elements: [{ ref, role, name, tag, nth, selector, line }],
//   count
// }
(() => {
  const trim = (v) => (typeof v === 'string' ? v : '')
    .replace(/\u00a0/g, ' ')
    .replace(/\r/g, '')
    .replace(/\s+/g, ' ')
    .trim();

  const normalize = (v) => trim(v).toLowerCase();

  // Remove refs from previous snapshots.
  document.querySelectorAll('[data-ai-ref], [data-ai-ref-id]').forEach((el) => {
    el.removeAttribute('data-ai-ref');
    el.removeAttribute('data-ai-ref-id');
  });

  const isHidden = (el) => {
    if (!(el instanceof Element)) return true;
    const style = window.getComputedStyle(el);
    if (style.display === 'none' || style.visibility === 'hidden' || parseFloat(style.opacity) <= 0) {
      return true;
    }
    const rect = el.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return true;
    let parent = el.parentElement;
    while (parent && parent !== document.body) {
      const ps = window.getComputedStyle(parent);
      if (ps.display === 'none' || ps.visibility === 'hidden') return true;
      parent = parent.parentElement;
    }
    return false;
  };

  const isInert = (el) => {
    if (!(el instanceof Element)) return true;
    return !!(el.disabled || el.getAttribute('aria-disabled') === 'true' || el.getAttribute('aria-hidden') === 'true');
  };

  const inferRole = (el) => {
    const explicit = trim(el.getAttribute('role'));
    if (explicit) return explicit;

    const tag = el.tagName.toLowerCase();
    if (tag === 'a' && el.getAttribute('href')) return 'link';
    if (tag === 'button') return 'button';
    if (tag === 'select') return 'combobox';
    if (tag === 'textarea') return 'textbox';
    if (tag === 'input') {
      const type = (el.getAttribute('type') || 'text').toLowerCase();
      if (type === 'checkbox') return 'checkbox';
      if (type === 'radio') return 'radio';
      if (type === 'submit' || type === 'button' || type === 'reset') return 'button';
      return 'textbox';
    }
    if (el.getAttribute('contenteditable') === 'true') return 'textbox';
    return tag;
  };

  const accessibleName = (el) => {
    const labelledBy = trim(el.getAttribute('aria-labelledby'));
    if (labelledBy) {
      const combined = labelledBy
        .split(/\s+/)
        .map((id) => document.getElementById(id))
        .filter(Boolean)
        .map((node) => trim(node.innerText || node.textContent || ''))
        .filter(Boolean)
        .join(' ');
      if (combined) return combined;
    }

    const ariaLabel = trim(el.getAttribute('aria-label'));
    if (ariaLabel) return ariaLabel;

    const id = trim(el.getAttribute('id'));
    if (id) {
      const byFor = document.querySelector('label[for="' + id.replace(/"/g, '\\"') + '"]');
      if (byFor) {
        const labelText = trim(byFor.innerText || byFor.textContent || '');
        if (labelText) return labelText;
      }
    }

    const parentLabel = el.closest('label');
    if (parentLabel) {
      const labelText = trim(parentLabel.innerText || parentLabel.textContent || '');
      if (labelText) return labelText;
    }

    return (
      trim(el.getAttribute('title')) ||
      trim(el.getAttribute('placeholder')) ||
      trim(el.getAttribute('alt')) ||
      trim(el.innerText || el.textContent || '') ||
      trim(el.getAttribute('value')) ||
      trim(el.getAttribute('name'))
    );
  };

  const buildSelectorHint = (el) => {
    const id = trim(el.getAttribute('id'));
    if (id) return '#' + id;
    const testId = trim(el.getAttribute('data-testid'));
    if (testId) return '[data-testid="' + testId.replace(/"/g, '\\"') + '"]';
    const name = trim(el.getAttribute('name'));
    if (name) return el.tagName.toLowerCase() + '[name="' + name.replace(/"/g, '\\"') + '"]';
    return null;
  };

  const interactiveSelector = [
    'a[href]',
    'button',
    'input:not([type="hidden"])',
    'textarea',
    'select',
    '[role="button"]',
    '[role="link"]',
    '[role="checkbox"]',
    '[role="radio"]',
    '[role="tab"]',
    '[role="menuitem"]',
    '[role="option"]',
    '[role="switch"]',
    '[contenteditable="true"]',
  ].join(',');

  const roleNameCount = new Map();
  const elements = [];
  let refIndex = 1;

  const candidates = Array.from(document.querySelectorAll(interactiveSelector));
  for (const el of candidates) {
    if (isHidden(el) || isInert(el)) continue;

    const role = inferRole(el);
    const name = accessibleName(el);
    const tag = el.tagName.toLowerCase();
    const key = normalize(role) + '::' + normalize(name);
    const nth = roleNameCount.get(key) || 0;
    roleNameCount.set(key, nth + 1);

    const ref = 'e' + String(refIndex);
    el.setAttribute('data-ai-ref', String(refIndex));
    el.setAttribute('data-ai-ref-id', ref);

    let extra = '';
    if (tag === 'a') {
      const href = trim(el.getAttribute('href'));
      if (href && href !== '#') extra = ' -> ' + href;
    } else if (tag === 'input') {
      const type = (el.getAttribute('type') || 'text').toLowerCase();
      extra = ' [' + type + ']';
    } else if (tag === 'select') {
      extra = ' [select]';
    } else if (tag === 'textarea') {
      extra = ' [textarea]';
    }

    const line = '[@' + ref + '] ' + role + (name ? ' "' + name + '"' : '') + extra;
    elements.push({
      ref,
      role,
      name,
      tag,
      nth,
      selector: buildSelectorHint(el),
      line,
    });
    refIndex += 1;
  }

  return JSON.stringify({
    title: trim(document.title) || null,
    finalUrl: window.location.href,
    elements,
    count: elements.length,
  });
})();
