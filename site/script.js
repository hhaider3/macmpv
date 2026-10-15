// The download picker and FAQ use native details elements and work without JS.
const year = document.getElementById("year");
if (year) year.textContent = "© " + new Date().getFullYear() + " macmpv contributors";

const picker = document.querySelector(".download-menu");
if (picker) {
    document.addEventListener("click", (event) => {
        if (!picker.contains(event.target)) picker.open = false;
    });
    document.addEventListener("keydown", (event) => {
        if (event.key === "Escape" && picker.open) {
            picker.open = false;
            picker.querySelector("summary").focus();
        }
    });
}

// Showcase clips play only while visible, and never with reduced motion; the
// poster image stands in otherwise (and without JS).
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
const clips = document.querySelectorAll(".showcase-video");
if (clips.length && "IntersectionObserver" in window) {
    const observer = new IntersectionObserver((entries) => {
        for (const entry of entries) {
            const clip = entry.target;
            if (entry.isIntersecting && !reduceMotion.matches) {
                clip.play().catch(() => {});
            } else {
                clip.pause();
            }
        }
    }, { threshold: 0.4 });
    clips.forEach((clip) => observer.observe(clip));
}
