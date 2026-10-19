// What github.com does around quote-selection's MarkdownQuote when `r` quotes a comment, so a
// quote here is the markdown github.com would write. Evaluated after quote-selection.js, in the
// app's own script world, as the body of a function: the caller appends the call it wants.

// github.com's own rules, applied to the selection before quote-selection's: a highlighted code
// block keeps its language, mentions, `#123` references and emoji stay as written, an embedded
// permalink becomes its link, a suggestion is dropped and a rendered diagram becomes its source.
const githubRules = {
  PRE(el) {
    const parent = el.parentElement
    if (parent && isHighlight(parent)) {
      const language = parent.className.match(/highlight-source-(\S+)/)?.[1] ?? ''
      const code = (el.textContent || '').replace(/\n+$/, '')
      el.textContent = `\`\`\`${language}\n${code}\n\`\`\``
      el.append('\n\n')
    }
    return el
  },
  A(el) {
    const text = el.textContent || ''
    const isReference = el.classList.contains('issue-link') && /^#\d+$/.test(text)
    return el.classList.contains('user-mention') || el.classList.contains('team-mention') || isReference ? text : el
  },
  IMG(el) {
    const alt = el.getAttribute('alt')
    return alt && el.classList.contains('emoji') ? alt : el
  },
  DIV(el) {
    if (el.classList.contains('js-suggested-changes-blob')) {
      el.remove()
    } else if (el.classList.contains('blob-wrapper-embedded')) {
      const embed = el.parentElement
      const link = document.createElement('p')
      link.textContent = embed.querySelector('a[href]').href
      embed.replaceWith(link)
    } else if (el.classList.contains('js-render-enrichment-target')) {
      const type = el.closest('.js-render-needs-enrichment').getAttribute('data-type')
      const pre = document.createElement('pre')
      pre.textContent = `\`\`\`${type}\n${el.getAttribute('data-plain')}\`\`\``
      return pre
    }
    return el
  }
}

function isHighlight(element) {
  return element.nodeName === 'DIV' && element.classList.contains('highlight')
}

// A MarkdownQuote of the selection as github.com makes one, scoped to a comment's body.
function githubQuote() {
  const quote = new MarkdownQuote('.body', fragment => {
    // The page's own additions to a body: reactions, the threads in a review's, and the
    // summary of a hidden comment.
    fragment.querySelectorAll('.reactions, details.thread, details.minimized > summary').forEach(added => added.remove())
    const codeBlock = quote.range.startContainer.parentElement?.closest('pre')
    const highlight = codeBlock?.parentElement
    if (highlight && isHighlight(highlight)) {
      const wrapper = document.createElement('div')
      wrapper.className = highlight.className
      wrapper.appendChild(fragment)
      fragment.appendChild(wrapper)
    }
    const iterator = document.createNodeIterator(fragment, NodeFilter.SHOW_ELEMENT, {
      acceptNode: node => node.nodeName in githubRules && (node.nodeName === 'IMG' || node.firstChild != null) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP
    })
    const matched = []
    for (let node = iterator.nextNode(); node; node = iterator.nextNode()) {
      if (node instanceof HTMLElement) matched.push(node)
    }
    for (const el of matched.reverse()) el.replaceWith(githubRules[el.nodeName](el))
  })
  styleScratch()
  return quote
}

// quote-selection reads the markdown back as the selected text of a copy laid out off screen
// at the page's top level, where a line break or a blank line follows a block according to its
// margins. On github.com that copy gets Primer's base styles; this page's own are reset for it,
// and Primer's put in their place.
function styleScratch() {
  if (document.getElementById('loupe-quote-scratch')) return
  const style = document.createElement('style')
  style.id = 'loupe-quote-scratch'
  const scratch = 'body > div[style*="-9999px"]'
  style.textContent = `
    ${scratch}, ${scratch} * { all: revert !important; }
    ${scratch} { position: absolute !important; left: -9999px !important; font-size: 14px !important; line-height: 1.5 !important; }
    ${scratch} p { margin: 0 0 10px !important; }
    ${scratch} :is(h1, h2, h3, h4, h5, h6, ul, ol, blockquote, pre, dd) { margin: 0 !important; }
    ${scratch} :is(ul, ol) { padding-left: 0 !important; }
    ${scratch} pre { font-size: 12px !important; }
    ${scratch} .render-needs-enrichment .render-plaintext-hidden { display: none !important; }
  `
  document.head.appendChild(style)
}

// What `r` quotes from the page's selection, as github.com does: the markdown of what's selected
// from where it starts in a comment, or all of that comment's body if only whitespace is, and the
// id of the thread the comment is in. Null when nothing is selected or it starts outside a comment.
function quoteSelection() {
  const selection = window.getSelection()
  if (!selection || selection.rangeCount === 0) return null
  const range = selection.getRangeAt(0)
  const start = range.startContainer.parentElement
  if (range.collapsed || !start) return null
  const comment = start.closest('.thread-comment, .card')
  // A thread's place and diff in a review are no comment's.
  if (!comment || (comment.matches('.card') && start.closest('details.thread'))) return null
  const body = comment.querySelector(':scope > .body, :scope > div > .body')
  if (!body) return null
  const quote = githubQuote()
  if (range.toString().trim() === '') quote.select(body)
  return { text: quote.selectionText, thread: comment.closest('details.thread')?.dataset.threadId ?? null }
}

// The markdown of a selection made elsewhere in a comment's body, which is put in `#source`
// first: from `start` to `end`, each `[node, offset]` with `node` counting the body's elements and
// text nodes in document order, and `offset` a text node's UTF-16 offset, or -1 before the node
// and -2 after it. Null for a range that selects nothing; one of nothing but whitespace quotes
// the whole body, as on github.com.
function quoteRange(start, end) {
  const body = document.getElementById('source')
  const nodes = []
  const walker = document.createTreeWalker(body, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT)
  while (walker.nextNode()) nodes.push(walker.currentNode)
  const range = document.createRange()
  const place = ([index, offset], set) => {
    const node = nodes[Math.min(index, nodes.length - 1)]
    if (!node) return false
    if (offset === -1) range[`set${set}Before`](node)
    else if (offset === -2) range[`set${set}After`](node)
    else range[`set${set}`](node, Math.min(offset, node.nodeType === Node.TEXT_NODE ? node.length : node.childNodes.length))
    return true
  }
  if (!place(start, 'Start') || !place(end, 'End') || range.collapsed) return null
  const selection = window.getSelection()
  selection.removeAllRanges()
  selection.addRange(range)
  const quote = githubQuote()
  if (range.toString().trim() === '') quote.select(body)
  return quote.selectionText
}
