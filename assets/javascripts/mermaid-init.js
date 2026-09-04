(function () {
  function renderMermaid() {
    if (typeof mermaid === "undefined") {
      return;
    }

    mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme: document.body.getAttribute("data-md-color-scheme") === "slate"
        ? "dark"
        : "default",
    });

    var nodes = Array.prototype.slice.call(
      document.querySelectorAll(".mermaid")
    ).filter(function (node) {
      return node.textContent.trim().length > 0;
    });

    if (nodes.length === 0) {
      return;
    }

    mermaid.run({ nodes: nodes });
  }

  if (window.document$) {
    window.document$.subscribe(renderMermaid);
  } else {
    document.addEventListener("DOMContentLoaded", renderMermaid);
  }
})();
