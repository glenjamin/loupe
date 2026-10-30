// Draws the page's mermaid diagrams where GitHub's HTML marks them, with the vendored Mermaid,
// which is evaluated before this in the same script world of the app's own. GitHub leaves a
// mermaid block for github.com to draw in a frame from its own host: a section with
// `data-type="mermaid"` holding the diagram's source as a code block. Here it's drawn into that
// section instead, so nothing is fetched. A diagram Mermaid can't draw stays as its code.

// Draws every diagram not yet drawn; returns how many were.
async function drawDiagrams() {
  const sections = [...document.querySelectorAll('section[data-type="mermaid"]:not([data-loupe-diagram])')];
  if (sections.length === 0) return 0;
  // The page's own light or dark, as GitHub's viewer follows github.com's theme.
  const dark = matchMedia('(prefers-color-scheme: dark)').matches;
  mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', suppressErrorRendering: true, theme: dark ? 'dark' : 'default' });
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
      section.append(diagram);
      section.dataset.loupeDiagram = 'drawn';
      drawn++;
    } catch {
      section.dataset.loupeDiagram = 'failed';
      // What Mermaid leaves in the body while drawing, should it fail part way.
      for (const leftover of document.querySelectorAll(`#${id}, #d${id}`)) leftover.remove();
    }
  }
  return drawn;
}

// A `var`, so evaluating the script again in the same page doesn't throw.
var diagramCount = diagramCount ?? 0;
