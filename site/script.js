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
