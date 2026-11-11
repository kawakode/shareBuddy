// Language: a saved choice wins, then the browser's preferred languages, then English.
// Runs in <head> so the page never shows the wrong language first.
(function () {
  var root = document.documentElement;
  var supported = { fr: true, en: true };

  function pick() {
    var saved = null;
    try { saved = localStorage.getItem("shareman-lang"); } catch (e) {}
    if (supported[saved]) return saved;
    var prefs = navigator.languages || [navigator.language || ""];
    for (var i = 0; i < prefs.length; i++) {
      var code = String(prefs[i]).slice(0, 2).toLowerCase();
      if (supported[code]) return code;
    }
    return "en";
  }

  function apply(lang) {
    root.lang = lang;
    var title = root.getAttribute("data-title-" + lang);
    if (title) document.title = title;
    var links = document.querySelectorAll("[data-set-lang]");
    for (var i = 0; i < links.length; i++) {
      links[i].classList.toggle("current", links[i].getAttribute("data-set-lang") === lang);
    }
  }

  apply(pick());

  // The app window illustration is drawn at a fixed size, then scaled to fit.
  function fitWindows() {
    var frames = document.querySelectorAll(".app-frame");
    for (var i = 0; i < frames.length; i++) {
      var win = frames[i].firstElementChild;
      var scale = Math.min(1, frames[i].clientWidth / win.offsetWidth);
      win.style.transform = scale < 1 ? "scale(" + scale + ")" : "";
      frames[i].style.height = win.offsetHeight * scale + "px";
    }
  }

  document.addEventListener("DOMContentLoaded", function () {
    apply(root.lang);
    var links = document.querySelectorAll("[data-set-lang]");
    for (var i = 0; i < links.length; i++) {
      links[i].addEventListener("click", function (event) {
        event.preventDefault();
        var lang = this.getAttribute("data-set-lang");
        try { localStorage.setItem("shareman-lang", lang); } catch (e) {}
        apply(lang);
        fitWindows();
      });
    }
    fitWindows();
    window.addEventListener("resize", fitWindows);
  });
})();
