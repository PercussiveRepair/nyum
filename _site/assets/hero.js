// Picks a random recipe photo as the backdrop of the home page header; if nothing suitable loads, the header stays plain
(function () {
    var header = document.getElementById("hero");
    var credit = document.getElementById("hero-credit");
    if (!header || !credit) return;

    var MAX_ATTEMPTS = 12;

    // judge candidates by their small thumbnail so rejected ones cost almost nothing
    function probe(pool, attempt) {
        if (attempt >= MAX_ATTEMPTS) return;
        var entry = pool[Math.floor(Math.random() * pool.length)];
        var thumb = new Image();
        thumb.onload = function () {
            if (thumb.naturalWidth < thumb.naturalHeight * 1.2) return probe(pool, attempt + 1);
            load(entry, pool, attempt);
        };
        thumb.onerror = function () { probe(pool, attempt + 1); };
        thumb.src = "thumbs/" + encodeURI(entry.image);
    }

    function load(entry, pool, attempt) {
        var full = new Image();
        full.onload = function () {
            if (full.naturalWidth < 700) return probe(pool, attempt + 1);
            header.style.setProperty("--hero-image", 'url("' + full.src + '")');
            header.classList.add("has-hero");
            var link = document.createElement("a");
            link.href = entry.htmlfile;
            link.textContent = "Photo: " + entry.title;
            credit.appendChild(link);
            credit.hidden = false;
        };
        full.onerror = function () { probe(pool, attempt + 1); };
        full.src = encodeURI(entry.image);
    }

    fetch("search.json")
        .then(function (response) { return response.json(); })
        .then(function (index) {
            var pool = index.filter(function (e) { return e.image && /\.(jpe?g|png)$/i.test(e.image); });
            if (pool.length) probe(pool, 0);
        })
        .catch(function () {});
})();
