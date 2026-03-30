(() => {
  const textOrEmpty = (value) => (typeof value === 'string' ? value : '');
  const trim = (value) => textOrEmpty(value).replace(/\u00a0/g, ' ').replace(/\r/g, '').trim();

  const cleanWhitespace = (value) => {
    return textOrEmpty(value)
      .replace(/\u00a0/g, ' ')
      .replace(/[ \t]+\n/g, '\n')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
  };

  const isNoise = (node) => {
    if (!(node instanceof Element)) return false;
    const tag = node.tagName.toLowerCase();
    if (['script', 'style', 'noscript', 'template', 'iframe', 'svg', 'canvas', 'nav', 'footer', 'header', 'aside', 'form'].includes(tag)) {
      return true;
    }
    const marker = (node.className || '') + ' ' + (node.id || '');
    return /nav|footer|header|sidebar|ads|promo|comment|share|breadcrumb/i.test(marker);
  };

  const isHidden = (node) => {
    if (!(node instanceof Element)) return false;
    const style = window.getComputedStyle(node);
    return style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0';
  };

  const candidateSelectors = [
    'article',
    'main',
    '[role="main"]',
    '.article',
    '.post',
    '.content',
    '#content',
    '#main'
  ];

  const collectCandidates = () => {
    const set = new Set();
    for (const selector of candidateSelectors) {
      document.querySelectorAll(selector).forEach((node) => set.add(node));
    }
    if (!set.size && document.body) {
      set.add(document.body);
    }
    return Array.from(set);
  };

  const scoreCandidate = (node) => {
    if (!(node instanceof Element)) return -1;
    const textLength = trim(node.innerText).length;
    if (textLength <= 0) return -1;
    const links = Array.from(node.querySelectorAll('a'));
    const linkTextLength = links.reduce((sum, link) => sum + trim(link.textContent).length, 0);
    return textLength - linkTextLength * 0.3;
  };

  const chooseRoot = () => {
    const candidates = collectCandidates();
    let best = document.body || document.documentElement;
    let bestScore = -1;
    for (const candidate of candidates) {
      const score = scoreCandidate(candidate);
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return best || document.body || document.documentElement;
  };

  const textForInline = (value) => {
    return trim(value)
      .replace(/\\/g, '\\\\')
      .replace(/`/g, '\\`');
  };

  const toMarkdown = (node, listDepth = 0) => {
    if (!node) return '';
    if (node.nodeType === Node.TEXT_NODE) {
      return textOrEmpty(node.textContent).replace(/\s+/g, ' ');
    }
    if (!(node instanceof Element)) {
      return '';
    }
    if (isNoise(node) || isHidden(node)) {
      return '';
    }

    const tag = node.tagName.toLowerCase();
    const children = () => Array.from(node.childNodes).map((child) => toMarkdown(child, listDepth)).join('');
    const content = () => cleanWhitespace(children());

    if (/^h[1-6]$/.test(tag)) {
      const level = Number(tag[1]);
      const heading = content();
      if (!heading) return '';
      return '\n\n' + '#'.repeat(level) + ' ' + heading + '\n\n';
    }

    switch (tag) {
    case 'p': {
      const paragraph = content();
      return paragraph ? '\n\n' + paragraph + '\n\n' : '';
    }
    case 'br':
      return '\n';
    case 'hr':
      return '\n\n---\n\n';
    case 'a': {
      const text = content();
      const href = trim(node.getAttribute('href'));
      if (!text) return '';
      if (!href) return text;
      return '[' + text + '](' + href + ')';
    }
    case 'img': {
      const alt = trim(node.getAttribute('alt'));
      const src = trim(node.getAttribute('src'));
      if (!src) return '';
      return '![' + alt + '](' + src + ')';
    }
    case 'pre': {
      const code = trim(node.innerText);
      if (!code) return '';
      return '\n\n```\n' + code + '\n```\n\n';
    }
    case 'code': {
      if (node.parentElement && node.parentElement.tagName.toLowerCase() === 'pre') {
        return '';
      }
      const inlineCode = textForInline(node.textContent);
      return inlineCode ? '`' + inlineCode + '`' : '';
    }
    case 'blockquote': {
      const quote = content();
      if (!quote) return '';
      const prefixed = quote.split('\n').map((line) => (line ? '> ' + line : '>')).join('\n');
      return '\n\n' + prefixed + '\n\n';
    }
    case 'ul': {
      const items = Array.from(node.children).filter((child) => child.tagName && child.tagName.toLowerCase() === 'li');
      if (!items.length) return '';
      const rendered = items.map((item) => {
        const itemText = cleanWhitespace(toMarkdown(item, listDepth + 1));
        if (!itemText) return '';
        const indent = '  '.repeat(listDepth);
        return indent + '- ' + itemText;
      }).filter(Boolean).join('\n');
      return rendered ? '\n' + rendered + '\n\n' : '';
    }
    case 'ol': {
      const items = Array.from(node.children).filter((child) => child.tagName && child.tagName.toLowerCase() === 'li');
      if (!items.length) return '';
      const rendered = items.map((item, index) => {
        const itemText = cleanWhitespace(toMarkdown(item, listDepth + 1));
        if (!itemText) return '';
        const indent = '  '.repeat(listDepth);
        return indent + (index + 1) + '. ' + itemText;
      }).filter(Boolean).join('\n');
      return rendered ? '\n' + rendered + '\n\n' : '';
    }
    case 'li':
      return content();
    case 'table': {
      const rows = Array.from(node.querySelectorAll('tr'));
      if (!rows.length) return '';
      const lines = rows.map((row) => {
        const cells = Array.from(row.querySelectorAll('th,td')).map((cell) => cleanWhitespace(cell.innerText));
        return cells.filter((cell) => cell.length > 0).join(' | ');
      }).filter((line) => line.length > 0);
      return lines.length ? '\n\n' + lines.join('\n') + '\n\n' : '';
    }
    default:
      return children();
    }
  };

  try {
    const root = chooseRoot();
    const markdown = cleanWhitespace(toMarkdown(root));
    const fallback = cleanWhitespace(document.body ? document.body.innerText : '');
    return JSON.stringify({
      title: trim(document.title) || null,
      finalUrl: window.location.href,
      markdown: markdown || fallback
    });
  } catch (_) {
    return JSON.stringify({
      title: trim(document.title) || null,
      finalUrl: window.location.href,
      markdown: cleanWhitespace(document.body ? document.body.innerText : '')
    });
  }
})();
