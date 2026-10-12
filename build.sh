#!/usr/bin/env bash

TIME_START=$(date +%s)

# exit on errors
set -e

# parse arguments
QUIET=false
CLEAN=false
REPORT=false
while [[ $# -gt 0 ]]; do
    if [ "$1" = "-q" ] || [ "$1" = "--quiet" ]; then
        QUIET=true
        shift
    elif [ "$1" = "-c" ] || [ "$1" = "--clean" ]; then
        CLEAN=true
        shift
    elif [ "$1" = "-r" ] || [ "$1" = "--report" ]; then
        REPORT=true
        shift
    elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        echo "Usage: bash build.sh [-q | --quiet] [-c | --clean] [-r | --report]"
        echo "  Builds the site. If the -c flag is given, stops after resetting _site/ and _temp/."
        echo "  If the -r flag is given, lists every recipe affected by each build warning instead of only counting them."
        exit
    else
        shift
    fi
done

function status {
    $QUIET && return
    BOLD=$(tput bold)
    NORMAL=$(tput sgr0)
    echo "${BOLD}$*${NORMAL}"
}

function x {
    _IFS="$IFS"
    IFS=" "
    $QUIET || echo "↪" "$*" >&2
    IFS="$_IFS"
    "$@"
}

# succeeds if the recipe's front matter names an image file that doesn't exist
function image_is_missing {
    local IMG
    IMG="$(head -40 "$1" | grep -m1 '^image:' | sed -E 's/^image:[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -n "$IMG" && ! -e "_recipes/$IMG" ]]
}

status "Resetting _site/ and _temp/..."
# (...with a twist, just to make sure this doesn't throw an error the first time)
x mkdir -p _site/
x touch _site/dummy.txt
x rm -r _site/
x mkdir -p _site/
x mkdir -p _temp/
x touch _temp/dummy.txt
x rm -r _temp/
x mkdir -p _temp/

$CLEAN && exit

status "Copying assets..."
x cp -r _assets/ _site/assets/

status "Copying static files..."
for FILE in _recipes/*; do
    [[ "$FILE" == *.md ]] && continue
    x cp "$FILE" _site/
done

status "Optimizing images..."
# writes downscaled copies over the ones just copied, plus small thumbnails for
# the index pages (needs Pillow; without it, the originals are used as-is)
if python3 -c "import PIL" 2>/dev/null; then
    x python3 _templates/technical/optimize_images.py _recipes _site
else
    echo "Pillow not found (pip install pillow), serving full-size images." >&2
    x mkdir -p _site/thumbs
    for FILE in _recipes/*.{jpg,jpeg,png}; do
        [ -e "$FILE" ] && x cp "$FILE" _site/thumbs/
    done
fi

status "Extracting metadata..."
for FILE in _recipes/*.md; do
    [[ "$(basename "$FILE")" == "recipe.md" ]] && continue  # authoring template, not a real recipe
    IMAGE_ARGS=()
    if image_is_missing "$FILE"; then
        IMAGE_ARGS=(--metadata image=)  # blank it out so no broken image is shown
        echo "$(basename "$FILE" .md)" >> _temp/missing_images.txt
    fi

    # extract category name for each recipe, set basename to avoid having to
    # use $sourcefile$ in the template which pandoc sets automatically but
    # contains the relative path
    x pandoc "$FILE" \
        --metadata-file config.yaml \
        --metadata basename="$(basename "$FILE" .md)" \
        --template _templates/technical/category.template.txt \
        -t html --wrap=none -o "_temp/$(basename "$FILE" .md).category.txt"

    # extract metadata, set htmlfile in order to link to it on the index page
    x pandoc "$FILE" \
        --metadata htmlfile="$(basename "$FILE" .md).html" \
        "${IMAGE_ARGS[@]}" \
        --template _templates/technical/metadata.template.json \
        -t html -o "_temp/$(basename "$FILE" .md).metadata.json"

    if [[ "$GITHUB_ACTIONS" = true ]]; then
        MDATE="$(git log -1 --date=short-local --pretty='format:%cd' "$FILE")"
    else
        MDATE="$(date -r "$FILE" "+%Y-%m-%d")"
    fi
    echo "$(basename "$FILE" .md) $MDATE" > "_temp/$(basename "$FILE" .md).mdate.txt"
done

status "Grouping metadata by category..."  # (yep, this is a right mess)
echo "{\"categories\": [" > _temp/index.json
SEPARATOR_OUTER=""  # no comma before first list element (categories)
SEPARATOR_INNER=""  # ditto (recipes per category)
IFS=$'\n'           # tell for loop logic to split on newlines only, not spaces
CATS="$(cat _temp/*.category.txt)"
for CATEGORY in $(echo "$CATS" | cut -d" " -f2- | sort | uniq); do
    printf '%s' "$SEPARATOR_OUTER" >> _temp/index.json
    CATEGORY_FAUX_URLENCODED="$(echo "$CATEGORY" | awk -f "_templates/technical/faux_urlencode.awk")"

    # some explanation on the next line and similar ones: this uses `tee -a`
    # instead of `>>` to append to two files instead of one, but since we don't
    # actually want to see the output, pipe that to /dev/null
    x printf '%s' "{\"category\": \"$CATEGORY\", \"category_faux_urlencoded\": \"$CATEGORY_FAUX_URLENCODED\", \"recipes\": [" | tee -a "_temp/index.json" "_temp/$CATEGORY_FAUX_URLENCODED.category.json" >/dev/null
    for C in $CATS; do
        BASENAME=$(echo "$C" | cut -d" " -f1)
        C_CAT=$(echo "$C" | cut -d" " -f2-)
        if [[ "$C_CAT" == "$CATEGORY" ]]; then
            printf '%s' "$SEPARATOR_INNER" | tee -a "_temp/index.json" "_temp/$CATEGORY_FAUX_URLENCODED.category.json" >/dev/null
            x cat "_temp/$BASENAME.metadata.json" | tee -a "_temp/index.json" "_temp/$CATEGORY_FAUX_URLENCODED.category.json" >/dev/null
            SEPARATOR_INNER=","
        fi
    done
    x printf "]}\n" | tee -a "_temp/index.json" "_temp/$CATEGORY_FAUX_URLENCODED.category.json" >/dev/null
    SEPARATOR_OUTER=","
    SEPARATOR_INNER=""
done
unset IFS
echo "]}" >> _temp/index.json

status "Building recent recipes list..."
# Collect all "<date> <basename>" pairs, sort descending, take top 20
RECENT_BASENAMES=$(
    for F in _temp/*.mdate.txt; do
        BASENAME=$(cat "$F" | cut -d" " -f1)
        MDATE=$(cat "$F" | cut -d" " -f2)
        echo "$MDATE $BASENAME"
    done | sort -r | head -20 | awk '{print $2}'
)

echo "{\"recent_recipes\": [" > _temp/recent.json
SEPARATOR_RECENT=""
for BASENAME in $RECENT_BASENAMES; do
    printf '%s' "$SEPARATOR_RECENT" >> _temp/recent.json
    cat "_temp/$BASENAME.metadata.json" >> _temp/recent.json
    SEPARATOR_RECENT=","
done
echo "]}" >> _temp/recent.json

status "Building recipe pages..."
for FILE in _recipes/*.md; do
    [[ "$(basename "$FILE")" == "recipe.md" ]] && continue  # authoring template, not a real recipe
    IMAGE_ARGS=()
    image_is_missing "$FILE" && IMAGE_ARGS=(--metadata image=)
    CATEGORY_FAUX_URLENCODED="$(cat "_temp/$(basename "$FILE" .md).category.txt" | cut -d" " -f2- | awk -f "_templates/technical/faux_urlencode.awk")"

    # when running under GitHub Actions, all file modification dates are set to
    # the date of the checkout (i.e., the date on which the workflow was
    # executed), so in that case, use the most recent commit date of each recipe
    # as its update date – you'll probably also want to set the TZ environment
    # variable to your local timezone in the workflow file (#21)
    if [[ "$GITHUB_ACTIONS" = true ]]; then
        UPDATED_AT="$(git log -1 --date=short-local --pretty='format:%cd' "$FILE")"
    else
        UPDATED_AT="$(date -r "$FILE" "+%Y-%m-%d")"
    fi

    # set basename to enable linking to github in the footer, and set
    # category_faux_urlencoded in order to link to that in the header
    x pandoc "$FILE" \
        --metadata-file config.yaml \
        --metadata basename="$(basename "$FILE" .md)" \
        --metadata category_faux_urlencoded="$CATEGORY_FAUX_URLENCODED" \
        --metadata updatedtime="$UPDATED_AT" \
        "${IMAGE_ARGS[@]}" \
        --template _templates/recipe.template.html \
        -o "_site/$(basename "$FILE" .md).html"
done

status "Building category pages..."
for FILE in _temp/*.category.json; do
    x pandoc _templates/technical/empty.md \
        --metadata-file config.yaml \
        --metadata title="dummy" \
        --metadata updatedtime="$(date "+%Y-%m-%d")" \
        --metadata-file "$FILE" \
        --template _templates/category.template.html \
        -o "_site/$(basename "$FILE" .category.json).html"
done

status "Building favourites page..."
# same shape as a category file, so the category template can render it; a
# non-empty "favorite" value in the metadata marks a recipe as a favourite
printf '%s' "{\"category\": \"Favourites\", \"category_faux_urlencoded\": \"favourites\", \"recipes\": [" > _temp/favourites.json
FAVOURITES_COUNT=0
SEPARATOR_FAVOURITES=""
for FILE in _temp/*.metadata.json; do
    if grep -q '"favorite":"[^"]' "$FILE"; then
        printf '%s' "$SEPARATOR_FAVOURITES" >> _temp/favourites.json
        cat "$FILE" >> _temp/favourites.json
        SEPARATOR_FAVOURITES=","
        FAVOURITES_COUNT=$((FAVOURITES_COUNT+1))
    fi
done
echo "]}" >> _temp/favourites.json
echo "{\"favourites_count\": $FAVOURITES_COUNT}" > _temp/favourites_count.json
x pandoc _templates/technical/empty.md \
    --metadata-file config.yaml \
    --metadata title="dummy" \
    --metadata updatedtime="$(date "+%Y-%m-%d")" \
    --metadata-file _temp/favourites.json \
    --template _templates/category.template.html \
    -o _site/favourites.html

status "Building index page..."
x pandoc _templates/technical/empty.md \
    --metadata-file config.yaml \
    --metadata title="dummy" \
    --metadata updatedtime="$(date "+%Y-%m-%d")" \
    --metadata-file _temp/recent.json \
    --metadata-file _temp/favourites_count.json \
    --metadata-file _temp/index.json \
    --template _templates/index.template.html \
    -o _site/index.html

status "Building all-recipes page..."
x pandoc _templates/technical/empty.md \
    --metadata-file config.yaml \
    --metadata title="dummy" \
    --metadata updatedtime="$(date "+%Y-%m-%d")" \
    --metadata-file _temp/index.json \
    --template _templates/all-recipes.template.html \
    -o _site/all-recipes.html

status "Assembling search index..."
echo "[" > _temp/search.json
SEPARATOR=""
for FILE in _temp/*.metadata.json; do
    printf '%s' "$SEPARATOR" >> _temp/search.json
    x cat "$FILE" >> _temp/search.json
    SEPARATOR=","
done
echo "]" >> _temp/search.json
x cp -r _temp/search.json _site/

# list gaps in the recipes' metadata, ignoring the recipe template (already
# skipped above) and the reference pages in the "Notes" category
function warn_list {
    local COUNT="$1" LABEL="$2" NAMES="$3"
    [ "$COUNT" -eq 0 ] && return 0
    echo "  $COUNT $LABEL"
    if $REPORT; then echo "$NAMES" | sed 's/^/      /'; fi
}
if ! $QUIET; then
    status "Build warnings"
    MISSING_IMAGES="$(sort _temp/missing_images.txt 2>/dev/null || true)"
    warn_list "$(echo "$MISSING_IMAGES" | grep -c .)" "recipes name an image file that doesn't exist (no image shown)" "$MISSING_IMAGES"
    for FIELD in description size source; do
        NAMES=""
        for FILE in _recipes/*.md; do
            BASENAME="$(basename "$FILE" .md)"
            [ "$BASENAME" = "recipe" ] && continue
            [ "$(cut -d" " -f2- "_temp/$BASENAME.category.txt")" = "Notes" ] && continue
            head -40 "$FILE" | grep -q "^$FIELD:[[:space:]]*[^[:space:]]" || NAMES="$NAMES$BASENAME"$'\n'
        done
        NAMES="$(echo -n "$NAMES" | sed '/^$/d')"
        warn_list "$(echo "$NAMES" | grep -c .)" "recipes have no $FIELD" "$NAMES"
    done
    if ! $REPORT; then echo "  (run with --report to list them)"; fi
fi

TIME_END=$(date +%s)
TIME_TOTAL=$((TIME_END-TIME_START))

EMOJI="🍇🍈🍉🍊🍋🍌🍍🥭🍎🍏🍐🍑🍒🍓🥝🍅🥥🥑🍆🥔🥕🌽🌶️🥒🥬🥦"
status "All done after $TIME_TOTAL seconds!" "${EMOJI:RANDOM%${#EMOJI}:1}"
