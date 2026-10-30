// Draws the page's mermaid diagrams where GitHub's HTML marks them, with the vendored Mermaid,
// which is evaluated before this in the same script world of the app's own. GitHub leaves a
// mermaid block for github.com to draw in a frame from its own host: a section with
// `data-type="mermaid"` holding the diagram's source as a code block. Here it's drawn into that
// section instead, so nothing is fetched. A diagram Mermaid can't draw stays as its code.

// Draws every diagram not yet drawn, or with `redraw` those drawn already, in the page's
// current light or dark; returns how many were.
async function drawDiagrams(redraw = false) {
  const which = redraw ? '[data-loupe-diagram="drawn"]' : ':not([data-loupe-diagram])';
  const sections = [...document.querySelectorAll(`section[data-type="mermaid"]${which}`)];
  if (sections.length === 0) return 0;
  // The page's own light or dark, as GitHub's viewer follows github.com's theme.
  const dark = matchMedia('(prefers-color-scheme: dark)').matches;
  mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true, theme: dark ? 'dark' : 'default' });
  const scheme = dark ? 'dark' : 'light';
  let drawn = 0;
  for (const section of sections) {
    const id = `loupe-mermaid-${diagramCount++}`;
    const target = section.querySelector('.js-render-enrichment-target');
    const source = target?.dataset.plain ?? section.querySelector('pre')?.textContent ?? '';
    try {
      const { svg } = await mermaid.render(id, source);
      const diagram = document.createElement('div');
      diagram.className = 'mermaid-diagram';
      diagram.innerHTML = svg;
      if (target) target.hidden = true;
      const shown = section.querySelector('.mermaid-diagram');
      if (shown) shown.replaceWith(diagram); else section.append(diagram);
      section.dataset.loupeDiagram = 'drawn';
      drawn++;
    } catch {
      // One drawn before keeps showing, in the other theme, rather than turning back to code.
      if (!redraw) section.dataset.loupeDiagram = 'failed';
      // What Mermaid leaves in the body while drawing, should it fail part way.
      for (const leftover of document.querySelectorAll(`#${id}, #d${id}`)) leftover.remove();
    }
    // Which theme it was last drawn for, so whoever waits on a change of theme can tell.
    section.dataset.loupeScheme = scheme;
  }
  return drawn;
}

// `var`s, so evaluating the script again in the same page doesn't throw.
var diagramCount = diagramCount ?? 0;
// Drawn diagrams are drawn again when the page turns light or dark, as the rest of it restyles
// itself, since Mermaid sets each diagram's colours as it draws it.
var watchingScheme = watchingScheme ?? (matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => drawDiagrams(true)), true);
