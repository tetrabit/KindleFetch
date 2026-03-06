#!/bin/sh

zlib_download() {
    local index="$1"
    
    if [ ! -f "$TMP_DIR/search_results.json" ]; then
        echo "No search results found" >&2
        return 1
    fi
    
    local book_info="$(select_preferred_format_book_info "$index" "zlib")"
    if [ $? -ne 0 ] || [ -z "$book_info" ]; then
        echo "No EPUB/PDF version available from Z-Library for this title." >&2
        return 1
    fi
    
    local md5="$(get_json_value "$book_info" "md5")"
    local book_page=""

    local final_url="$(curl -s -L -o /dev/null -w "%{url_effective}" "$ZLIB_URL/md5/$md5")"

    # Legacy: /book/<id>/<hash>
    local book_id="$(echo "$final_url" | sed -n 's#.*/book/\([0-9][0-9]*\)/[[:alnum:]]\+\(/.*\)\?$#\1#p')"
    local book_hash="$(echo "$final_url" | sed -n 's#.*/book/[0-9][0-9]*/\([[:alnum:]]\+\)\(/.*\)\?$#\1#p')"

    # Current format: /book/<hash>
    if [ -z "$book_hash" ]; then
        book_hash="$(echo "$final_url" | sed -n 's#.*/book/\([[:alnum:]]\+\)\(/.*\)\?$#\1#p')"
    fi

    if [ -n "$book_hash" ]; then
        book_page="$(curl -s -L -b "$ZLIB_COOKIES_FILE" "$ZLIB_URL/book/$book_hash")"
        if echo "$book_page" | grep -qi "isn't available for download due to the complaint of the copyright holder"; then
            echo "This title is currently unavailable on Z-Library (copyright complaint)." >&2
            return 1
        fi
    fi

    # If URL does not contain numeric id, fetch page and extract it.
    if [ -z "$book_id" ] && [ -n "$book_hash" ]; then
        book_id="$(echo "$book_page" | sed -n 's/.*data-book_id="\([0-9][0-9]*\)".*/\1/p' | head -n1)"
        if [ -z "$book_id" ]; then
            book_id="$(echo "$book_page" | sed -n 's/.*CurrentBook = new Book({\"id\":\([0-9][0-9]*\).*/\1/p' | head -n1)"
        fi
    fi

    if [ -z "$book_id" ] || [ -z "$book_hash" ]; then
        echo "Failed to extract book info from URL: $final_url" >&2
        return 1
    fi

    local response="$(curl -s -b "$ZLIB_COOKIES_FILE" \
        -H "Accept: application/json" \
        -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64)" \
        "$ZLIB_URL/eapi/book/$book_id/$book_hash/file")"

    local ddl="$(get_json_value "$response" "downloadLink" | sed 's#\\\/#/#g' | tr -d '\r\n')"
    local title="$(get_json_value "$response" "description" | tr -d '\r\n')"
    local ext="$(get_json_value "$response" "extension" | tr -d '\r\n')"

    if [ -z "$title" ] || [ "$title" = "null" ]; then
        title="$(get_json_value "$book_info" "title" | tr -d '\r\n')"
    fi

    if [ -z "$ext" ] || [ "$ext" = "null" ]; then
        ext="$(get_json_value "$book_info" "format" | tr '[:upper:]' '[:lower:]' | tr -d '\r\n')"
    fi

    if [ -z "$ddl" ]; then
        if [ -z "$book_page" ] || ! echo "$book_page" | grep -q "addDownloadedBook"; then
            book_page="$(curl -s -L -b "$ZLIB_COOKIES_FILE" "$ZLIB_URL/book/$book_hash")"
        fi
        local dl_path="$(echo "$book_page" | sed -n 's#.*class="btn btn-default addDownloadedBook" href="\([^"]*\)".*#\1#p' | head -n1)"
        if [ -n "$dl_path" ]; then
            case "$dl_path" in
                http://*|https://*)
                    ddl="$dl_path"
                    ;;
                *)
                    ddl="$ZLIB_URL$dl_path"
                    ;;
            esac
        fi
    fi

    if [ -z "$ddl" ]; then
        echo "Failed to get download link from Z-Library response." >&2
        echo "$response" | head -n1
        return 1
    fi

    printf '\nDo you want to change filename? [y/N]: '
    read -r confirm
    if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
        printf '\nEnter your custom filename: '
        read -r custom_filename
        if [ -n "$custom_filename" ]; then
            local title="$(sanitize_filename "$custom_filename" | tr -d ' ')"
        else
            echo "Invalid filename. Proceeding with original filename."
        fi
    else
        echo "Proceeding with original filename."
    fi

    local file_size="$(curl -sI "$ddl" | awk '/Content-Length/ {printf "%.2f MB\n", $2/1048576}')"
    [ -z "$ext" ] && ext="bin"
    local filename="$(sanitize_filename "${title}.${ext}")"
    local filename="${filename:-book.bin}"
    
    if [ ! -w "$KINDLE_DOCUMENTS" ]; then
        echo "No write permission in $KINDLE_DOCUMENTS" >&2
        return 1
    fi

    if [ "$CREATE_SUBFOLDERS" = "true" ]; then
        local book_folder="$KINDLE_DOCUMENTS/$filename"
        if ! mkdir -p "$book_folder"; then
            echo "Failed to create folder '$book_folder'" >&2
            return 1
        fi
        local final_location="$book_folder/$filename"
    else
        local final_location="$KINDLE_DOCUMENTS/$filename"
    fi

    if [ -e "$final_location" ] && [ ! -w "$final_location" ]; then
        echo "No permission to overwrite $final_location" >&2
        return 1
    fi

    printf '\nDownloading:\n'
    printf "\nBook: $title\nExtension: $ext\nFile size: $file_size\nMD5: $md5\n"
    printf "\nProgress (Press Ctrl + c to stop):\n"

    if curl -L --progress-bar -b "$ZLIB_COOKIES_FILE" -o "$final_location" "$ddl"; then
        printf "\nDownload successful!\n"
        echo "Saved to: $final_location"
        return 0
    else
        echo "Download failed." >&2
        return 1
    fi
}
