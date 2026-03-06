#!/bin/sh

change_dns () {
    RESOLV_FILE="/var/run/resolv.conf"
    
    if [ ! -f "$RESOLV_FILE" ]; then
        exit 1
    fi

    sed -i '/^nameserver/d' "$RESOLV_FILE"

    echo "nameserver 1.1.1.1" >> "$RESOLV_FILE"
    echo "nameserver 1.0.0.1" >> "$RESOLV_FILE"
}

load_config() {
    eval "$(base64 -d "$LINK_CONFIG_FILE")"
    if [ -f "$CONFIG_FILE" ]; then
        . "$CONFIG_FILE"
    else
        first_time_setup
    fi
}

load_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        echo "Version file wasn't found!"
        sleep 2
        echo "Creating version file"
        sleep 2
        get_version
    fi
}

sanitize_filename() {
    echo "$1" | sed -e 's/[^[:alnum:]\._-]/_/g' -e 's/ /_/g'
}

normalize_title() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^[:alnum:]]//g'
}

get_json_value() {
    echo "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed "s/\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\"/\1/" || \
    echo "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*[^,}]*" | sed "s/\"$2\"[[:space:]]*:[[:space:]]*\([^,}]*\)/\1/"
}

ensure_config_dir() {
    local config_dir="$(dirname "$CONFIG_FILE")"
    if [ ! -d "$config_dir" ]; then
        mkdir -p "$config_dir"
    fi
}

cleanup() {
    rm -f "$TMP_DIR"/kindle_books.list \
          "$TMP_DIR"/kindle_folders.list \
          "$TMP_DIR"/search_results.json \
          "$TMP_DIR"/last_search_*
}

get_version() {
    local api_response="$(curl -s -H "Accept: application/vnd.github.v3+json" "https://api.github.com/repos/justrals/KindleFetch/commits")" || {
        echo "Failed to fetch version from GitHub API" >&2
        echo "unknown"
        return
    }

    local latest_sha="$(echo "$api_response" | grep -m1 '"sha":' | cut -d'"' -f4 | cut -c1-7)"
    
    echo "$latest_sha" > "$VERSION_FILE"
    load_version
}

check_for_updates() {
    local current_sha="$(load_version)"
    
    local latest_sha="$(curl -s -H "Accept: application/vnd.github.v3+json" \
        -H "Cache-Control: no-cache" \
        "https://api.github.com/repos/justrals/KindleFetch/commits?per_page=1" | \
        grep -oE '"sha": "[0-9a-f]+"' | head -1 | cut -d'"' -f4 | cut -c1-7)"
    
    if [ -n "$latest_sha" ] && [ "$current_sha" != "$latest_sha" ]; then
        UPDATE_AVAILABLE=true
        return 0
    else
        return 1
    fi
}

save_config() {
    {
        echo "KINDLE_DOCUMENTS=\"$KINDLE_DOCUMENTS\""
        echo "CREATE_SUBFOLDERS=\"$CREATE_SUBFOLDERS\""
        echo "DEBUG_MODE=\"$DEBUG_MODE\""
        echo "COMPACT_OUTPUT=\"$COMPACT_OUTPUT\""
        echo "ENFORCE_DNS=\"$ENFORCE_DNS\""
        echo "ZLIB_AUTH=\"$ZLIB_AUTH\""
        echo "ZLIB_USERNAME=\"$ZLIB_USERNAME\""
        echo "RESULTS_PER_PAGE=\"$RESULTS_PER_PAGE\""
        echo "ANNAS_URL=\"$ANNAS_URL\""
        echo "LGLI_URL=\"$LGLI_URL\""
        echo "ZLIB_URL=\"$ZLIB_URL\""
    } > "$CONFIG_FILE"
}

zlib_login() {
    local zlib_login="$1"
    local zlib_password="$2"

    printf '\nLogging in to Z-Library...'

    local response="$(curl -s -c "$ZLIB_COOKIES_FILE" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Accept: application/json" \
        -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
        -X POST -d "email=$zlib_login&password=$zlib_password" \
        "$ZLIB_URL/eapi/user/login")"

    local zlib_username="$(get_json_value "$response" "name" | tr -d '\r\n')"

    if [ -n "$zlib_username" ]; then
        printf "\nSuccessfully logged in as $zlib_username!"
        ZLIB_USERNAME="$zlib_username"
        sleep 2
    else
        printf "\nLogin failed." >&2
        printf "\n$response" | head -n1
        sleep 2
        return 1
    fi
}

find_working_url() {
    for url in "$@"; do
        attempt=1
        while [ "$attempt" -le 5 ]; do
            code=$(curl -s -o /dev/null -w '%{http_code}' \
                   --max-time 10 -L "$url")
            curl_status=$?

            if [ "$curl_status" -eq 0 ] && [ "$code" != "000" ] && [ "$code" -lt 500 ]; then
                echo "$url"
                return 0
            fi

            attempt=$((attempt + 1))
            [ "$attempt" -le 5 ] && sleep 1
        done
    done
    return 1
}

zlib_md5_is_downloadable() {
    local md5="$1"
    local cache_file="${TMP_DIR}/zlib_availability.cache"
    local cached_status=""
    local final_url=""
    local book_hash=""
    local book_page=""

    [ -z "$md5" ] && return 0

    if [ -f "$cache_file" ]; then
        cached_status="$(awk -F'|' -v m="$md5" '$1 == m {print $2; exit}' "$cache_file")"
        case "$cached_status" in
            ok) return 0 ;;
            blocked) return 1 ;;
        esac
    fi

    final_url="$(curl -s -L -o /dev/null -w "%{url_effective}" "$ZLIB_URL/md5/$md5")"
    book_hash="$(echo "$final_url" | sed -n 's#.*/book/\([[:alnum:]]\+\)\(/.*\)\?$#\1#p')"

    if [ -z "$book_hash" ]; then
        echo "$md5|ok" >> "$cache_file"
        return 0
    fi

    if [ -f "$ZLIB_COOKIES_FILE" ]; then
        book_page="$(curl -s -L -b "$ZLIB_COOKIES_FILE" "$ZLIB_URL/book/$book_hash")"
    else
        book_page="$(curl -s -L "$ZLIB_URL/book/$book_hash")"
    fi

    if echo "$book_page" | grep -qi "isn't available for download due to the complaint of the copyright holder"; then
        echo "$md5|blocked" >> "$cache_file"
        return 1
    fi

    echo "$md5|ok" >> "$cache_file"
    return 0
}

select_preferred_format_book_info() {
    local index="$1"
    local provider="$2"

    if [ ! -f "$TMP_DIR/search_results.json" ]; then
        return 1
    fi

    local selected_book_info="$(awk -v i="$index" 'BEGIN{RS="\\{"; FS="\\}"} NR==i+1{print $1}' "$TMP_DIR"/search_results.json)"
    if [ -z "$selected_book_info" ]; then
        return 1
    fi

    local selected_title="$(get_json_value "$selected_book_info" "title")"
    local selected_key="$(normalize_title "$selected_title")"

    local total_books="$(grep -o '"title":' "$TMP_DIR"/search_results.json | wc -l)"
    local preferred_pdf=""
    local i=1

    while [ "$i" -le "$total_books" ]; do
        local candidate="$(awk -v i="$i" 'BEGIN{RS="\\{"; FS="\\}"} NR==i+1{print $1}' "$TMP_DIR"/search_results.json)"
        if [ -n "$candidate" ]; then
            local candidate_description="$(get_json_value "$candidate" "description" | tr '[:upper:]' '[:lower:]')"
            if echo "$candidate_description" | grep -q "$provider"; then
                local candidate_title="$(get_json_value "$candidate" "title")"
                local candidate_key="$(normalize_title "$candidate_title")"
                if [ "$candidate_key" = "$selected_key" ]; then
                    local candidate_md5="$(get_json_value "$candidate" "md5")"
                    if [ "$provider" = "zlib" ]; then
                        if ! zlib_md5_is_downloadable "$candidate_md5"; then
                            i=$((i + 1))
                            continue
                        fi
                    fi
                    local candidate_format="$(get_json_value "$candidate" "format" | tr '[:upper:]' '[:lower:]')"
                    case "$candidate_format" in
                        epub)
                            echo "$candidate"
                            return 0
                            ;;
                        pdf)
                            [ -z "$preferred_pdf" ] && preferred_pdf="$candidate"
                            ;;
                    esac
                fi
            fi
        fi
        i=$((i + 1))
    done

    if [ -n "$preferred_pdf" ]; then
        echo "$preferred_pdf"
        return 0
    fi

    return 1
}
