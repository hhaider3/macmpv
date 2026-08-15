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
