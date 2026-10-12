// Adds a "Keep screen on" toggle to the info list of recipe pages, but only where the Wake Lock API is available (it also needs https)
(function () {
    var list = document.querySelector("main.recipe header ul");
    if (!list || !("wakeLock" in navigator)) return;

    var item = document.createElement("li");
    item.className = "wakelock";
    item.innerHTML = '<button type="button" aria-pressed="false"><img src="assets/tabler-icons/tabler-icon-sun.svg" alt=""> <span>Keep screen on</span></button>';
    list.appendChild(item);

    var button = item.querySelector("button");
    var label = item.querySelector("span");
    var lock = null;
    var wanted = false;

    function render() {
        button.setAttribute("aria-pressed", wanted ? "true" : "false");
        label.textContent = wanted ? "Screen stays on" : "Keep screen on";
    }

    function acquire() {
        navigator.wakeLock.request("screen").then(function (sentinel) {
            lock = sentinel;
            lock.addEventListener("release", function () { lock = null; });
        }).catch(function () {
            wanted = false;
            render();
        });
    }

    button.addEventListener("click", function () {
        wanted = !wanted;
        render();
        if (wanted) {
            acquire();
        } else if (lock) {
            lock.release();
        }
    });

    // the browser drops the lock when the tab is hidden, so take it again on return
    document.addEventListener("visibilitychange", function () {
        if (wanted && !lock && document.visibilityState === "visible") acquire();
    });
})();
