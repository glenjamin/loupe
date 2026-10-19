// @github/quote-selection 2.2.0, https://github.com/github/quote-selection: src/index.ts and
// src/markdown.ts with their types taken out, otherwise as published. github.com quotes a
// comment's selection into a reply with it.
//
// Copyright (c) 2018-2020 GitHub, Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to
// the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
// LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
// OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
// WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

// src/markdown.ts

function indexInList(li) {
  const parent = li.parentNode

  if (parent === null || !(parent instanceof HTMLElement)) throw new Error()

  let start = 0
  if (parent instanceof HTMLOListElement && parent.start !== 1) {
    start = parent.start - 1
  }

  const ref = parent.children
  for (let i = 0; i < ref.length; ++i) {
    if (ref[i] === li) {
      return start + i
    }
  }
  return start
}

// Skip processing links that only link to the src of image within.
function skipNode(node) {
  if (node instanceof HTMLAnchorElement && node.childNodes.length === 1) {
    const first = node.childNodes[0]
    if (first instanceof HTMLImageElement) {
      return first.src === node.href
    }
  }
  return false
}

function hasContent(node) {
  return node.nodeName === 'IMG' || node.firstChild != null
}

function isCheckbox(node) {
  return node.nodeName === 'INPUT' && node instanceof HTMLInputElement && node.type === 'checkbox'
}

let listIndexOffset = 0

function nestedListExclusive(li) {
  const first = li.childNodes[0]
  const second = li.childNodes[1]
  if (first && li.childNodes.length < 3) {
    return (
      (first.nodeName === 'OL' || first.nodeName === 'UL') &&
      (!second || (second.nodeType === Node.TEXT_NODE && !(second.textContent || '').trim()))
    )
  }

  return false
}

function escapeAttribute(text) {
  return text
    .replace(/&/g, '&amp;')
    .replace(/'/g, '&apos;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
}

const filters = {
  INPUT(el) {
    if (el instanceof HTMLInputElement && el.checked) {
      return '[x] '
    }
    return '[ ] '
  },
  CODE(el) {
    const text = el.textContent || ''

    if (el.parentNode && el.parentNode.nodeName === 'PRE') {
      el.textContent = `\`\`\`\n${text.replace(/\n+$/, '')}\n\`\`\`\n\n`
      return el
    }
    if (text.indexOf('`') >= 0) {
      return `\`\` ${text} \`\``
    }
    return `\`${text}\``
  },
  P(el) {
    const pElement = document.createElement('p')
    const text = el.textContent || ''
    pElement.textContent = text.replace(/<(\/?)(pre|strong|weak|em)>/g, '\\<$1$2\\>')
    return pElement
  },
  STRONG(el) {
    return `**${el.textContent || ''}**`
  },
  EM(el) {
    return `_${el.textContent || ''}_`
  },
  DEL(el) {
    return `~${el.textContent || ''}~`
  },
  BLOCKQUOTE(el) {
    const text = (el.textContent || '').trim().replace(/^/gm, '> ')
    const pre = document.createElement('pre')
    pre.textContent = `${text}\n\n`
    return pre
  },
  A(el) {
    const text = el.textContent || ''
    const href = el.getAttribute('href')

    if (/^https?:/.test(text) && text === href) {
      return text
    } else {
      if (href) {
        return `[${text}](${href})`
      } else {
        return text
      }
    }
  },
  IMG(el) {
    const alt = el.getAttribute('alt') || ''
    const src = el.getAttribute('src')
    if (!src) throw new Error()

    const widthAttr = el.hasAttribute('width') ? ` width="${escapeAttribute(el.getAttribute('width') || '')}"` : ''
    const heightAttr = el.hasAttribute('height') ? ` height="${escapeAttribute(el.getAttribute('height') || '')}"` : ''

    if (widthAttr || heightAttr) {
      // eslint-disable-next-line github/unescaped-html-literal
      return `<img alt="${escapeAttribute(alt)}"${widthAttr}${heightAttr} src="${escapeAttribute(src)}">`
    } else {
      return `![${alt}](${src})`
    }
  },
  LI(el) {
    const list = el.parentNode
    if (!list) throw new Error()

    let bullet = ''
    if (!nestedListExclusive(el)) {
      if (list.nodeName === 'OL') {
        if (listIndexOffset > 0 && !list.previousSibling) {
          const num = indexInList(el) + listIndexOffset + 1
          bullet = `${num}\\. `
        } else {
          bullet = `${indexInList(el) + 1}. `
        }
      } else {
        bullet = '* '
      }
    }

    const indent = bullet.replace(/\S/g, ' ')
    const text = (el.textContent || '').trim().replace(/^/gm, indent)
    const pre = document.createElement('pre')
    pre.textContent = text.replace(indent, bullet)
    return pre
  },
  OL(el) {
    const li = document.createElement('li')
    li.appendChild(document.createElement('br'))
    el.append(li)
    return el
  },
  H1(el) {
    const level = parseInt(el.nodeName.slice(1))
    el.prepend(`${Array(level + 1).join('#')} `)
    return el
  },
  UL(el) {
    return el
  }
}
filters.UL = filters.OL
for (let level = 2; level <= 6; ++level) {
  filters[`H${level}`] = filters.H1
}

function insertMarkdownSyntax(root) {
  const nodeIterator = document.createNodeIterator(root, NodeFilter.SHOW_ELEMENT, {
    acceptNode(node) {
      if (node.nodeName in filters && !skipNode(node) && (hasContent(node) || isCheckbox(node))) {
        return NodeFilter.FILTER_ACCEPT
      }

      return NodeFilter.FILTER_SKIP
    }
  })
  const results = []
  let node = nodeIterator.nextNode()

  while (node) {
    if (node instanceof HTMLElement) {
      results.push(node)
    }
    node = nodeIterator.nextNode()
  }

  // process deepest matches first
  results.reverse()

  for (const el of results) {
    el.replaceWith(filters[el.nodeName](el))
  }
}

function extractFragment(range, selector) {
  const startNode = range.startContainer
  if (!startNode || !startNode.parentNode || !(startNode.parentNode instanceof HTMLElement)) {
    throw new Error('the range must start within an HTMLElement')
  }
  const parent = startNode.parentNode

  let fragment = range.cloneContents()
  if (selector) {
    const contentElement = fragment.querySelector(selector)
    if (contentElement) {
      fragment = document.createDocumentFragment()
      fragment.appendChild(contentElement)
    }
  }

  listIndexOffset = 0
  const li = parent.closest('li')
  const codeBlock = parent.closest('pre')
  if (codeBlock) {
    const pre = document.createElement('pre')
    pre.appendChild(fragment)
    fragment = document.createDocumentFragment()
    fragment.appendChild(pre)
  } else if (li && li.parentNode) {
    if (li.parentNode.nodeName === 'OL') {
      listIndexOffset = indexInList(li)
    }
    if (!fragment.querySelector('li')) {
      const item = document.createElement('li')

      if (!li.parentNode) throw new Error()
      const list = document.createElement(li.parentNode.nodeName)

      item.appendChild(fragment)
      list.appendChild(item)
      fragment = document.createDocumentFragment()
      fragment.appendChild(list)
    }
  }

  return fragment
}

// src/index.ts

class Quote {
  selection = window.getSelection()
  processSelectionText = str => str

  closest(selector) {
    const startContainer = this.range.startContainer
    const startElement = startContainer instanceof Element ? startContainer : startContainer.parentElement
    if (!startElement) return null

    return startElement.closest(selector)
  }

  get active() {
    return (this.selection?.rangeCount || 0) > 0
  }

  get range() {
    return this.selection?.rangeCount ? this.selection.getRangeAt(0) : new Range()
  }

  set range(range) {
    this.selection?.removeAllRanges()
    this.selection?.addRange(range)
  }

  set processSelectionTextFn(fn) {
    this.processSelectionText = fn
  }

  get selectionText() {
    return this.processSelectionText(this.selection?.toString().trim() || '')
  }

  get quotedText() {
    return `> ${this.selectionText.replace(/\n/g, '\n> ')}\n\n`
  }

  select(element) {
    if (this.selection) {
      this.selection.removeAllRanges()
      this.selection.selectAllChildren(element)
    }
  }

  insert(field) {
    if (field.value) {
      field.value = `${field.value}\n\n${this.quotedText}`
    } else {
      field.value = this.quotedText
    }

    field.dispatchEvent(
      new CustomEvent('change', {
        bubbles: true,
        cancelable: false
      })
    )
    field.focus()
    field.selectionStart = field.value.length
    field.scrollTop = field.scrollHeight
  }
}

class MarkdownQuote extends Quote {
  constructor(scopeSelector = '', callback) {
    super()
    this.scopeSelector = scopeSelector
    this.callback = callback
  }

  get selectionText() {
    if (!this.selection) return ''
    const fragment = extractFragment(this.range, this.scopeSelector ?? '')
    this.callback?.(fragment)
    insertMarkdownSyntax(fragment)
    const body = document.body
    if (!body) return ''

    const div = document.createElement('div')
    div.appendChild(fragment)
    div.style.cssText = 'position:absolute;left:-9999px;'
    body.appendChild(div)
    let selectionText = ''
    try {
      const range = document.createRange()
      range.selectNodeContents(div)
      this.selection.removeAllRanges()
      this.selection.addRange(range)
      selectionText = this.selection.toString()
      this.selection.removeAllRanges()
      range.detach()
    } finally {
      body.removeChild(div)
    }
    return this.processSelectionText(selectionText.trim())
  }
}
