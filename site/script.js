// Progressive enhancement only: scroll reveals, year stamp.
// Without JS the page renders fully and remains usable.

document.documentElement.classList.add("js");

const observer = new IntersectionObserver(
    (entries) => {
        for (const entry of entries) {
            if (entry.isIntersecting) {
                entry.target.classList.add("revealed");
                observer.unobserve(entry.target);
            }
        }
    },
    { threshold: 0.12 }
);

document.querySelectorAll(".reveal").forEach((element) => {
    observer.observe(element);
});

document.getElementById("year").textContent =
    "© " + new Date().getFullYear() + " macmpv contributors";

// Download build picker: click the hero button to choose Standard or + Torrents.
const downloadMenu = document.querySelector(".download-menu");
const downloadToggle = document.getElementById("download-button");
if (downloadMenu && downloadToggle) {
    const setMenuOpen = (open) => {
        downloadMenu.classList.toggle("open", open);
        downloadToggle.setAttribute("aria-expanded", String(open));
    };
    downloadToggle.addEventListener("click", (event) => {
        event.stopPropagation();
        setMenuOpen(!downloadMenu.classList.contains("open"));
    });
    document.addEventListener("click", (event) => {
        if (!downloadMenu.contains(event.target)) setMenuOpen(false);
    });
    document.addEventListener("keydown", (event) => {
        if (event.key === "Escape") setMenuOpen(false);
    });
}
