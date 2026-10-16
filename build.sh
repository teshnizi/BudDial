#!/bin/zsh
# Tests, builds and installs Buddial. The app is signed with a stable
# local identity so macOS keeps its Microphone and Accessibility grants across
# rebuilds (an ad-hoc signature changes every build and silently loses them).
set -eu
root="${0:A:h}"
src="$root/src"
app_dir="$HOME/Applications/Buddial.app"
# The Command Line Tools' macOS 27.0 SDK ships malformed .tbd stubs; use 26.5 where it is installed.
sdk_dir="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
[[ -d "$sdk_dir" ]] || sdk_dir=$(xcrun --show-sdk-path)
signing="$root/signing"
keychain="$signing/buddial.keychain-db"
identity_name="Buddial Local Signing"

ensure_identity() {
    mkdir -p "$signing"; chmod 700 "$signing"
    if [[ ! -f "$keychain" ]]; then
        openssl rand -hex 24 > "$signing/keychain-password"; chmod 600 "$signing/keychain-password"
        local pw=$(<"$signing/keychain-password") p12pw=$(openssl rand -hex 12)
        cat > "$signing/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $identity_name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
        openssl req -x509 -newkey rsa:2048 -nodes -keyout "$signing/key.pem" -out "$signing/cert.pem" -days 3650 -config "$signing/cert.cnf" 2>/dev/null
        # Legacy PKCS#12 encryption: macOS cannot import the OpenSSL 3+ defaults.
        openssl pkcs12 -export -inkey "$signing/key.pem" -in "$signing/cert.pem" -out "$signing/identity.p12" -passout "pass:$p12pw" \
            -name "$identity_name" -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
        security create-keychain -p "$pw" "$keychain"
        security set-keychain-settings "$keychain"
        security unlock-keychain -p "$pw" "$keychain"
        security import "$signing/identity.p12" -k "$keychain" -P "$p12pw" -T /usr/bin/codesign >/dev/null
        security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$keychain" >/dev/null
        rm -f "$signing/key.pem" "$signing/identity.p12"
    fi
    security unlock-keychain -p "$(<"$signing/keychain-password")" "$keychain"
    # codesign only finds identities in keychains on the user search list, even with --keychain.
    local -a searchlist
    searchlist=("${(@f)$(security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"$/\1/')}")
    if (( ! ${searchlist[(Ie)$keychain]} )); then
        security list-keychains -d user -s "${searchlist[@]}" "$keychain"
    fi
    if ! security find-identity -v -p codesigning "$keychain" | grep -q "\"$identity_name\""; then
        echo "One-time step: approve the macOS dialog that trusts the local signing certificate."
        security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$signing/cert.pem"
    fi
    identity=$(security find-identity -v -p codesigning "$keychain" | awk -v name="\"$identity_name\"" 'index($0, name) {print $2; exit}')
    [[ -n "$identity" ]] || { echo "Signing identity is not trusted for code signing." >&2; exit 1; }
}

engine_source=/opt/homebrew/bin/whisper-server

# Prints the file that Mach-O $1 (a real path) loads as $2, resolving @rpath and @loader_path as dyld does.
resolve_library() {
    local file=$1 name=$2 candidate rpath
    case $name in
        @rpath/*)
            for rpath in ${(f)"$(otool -l "$file" | awk '$2 == "LC_RPATH" {getline; getline; print $2}')"}; do
                rpath=${rpath/#@loader_path/${file:h}}; rpath=${rpath/#@executable_path/${engine_source:A:h}}
                candidate="$rpath/${name#@rpath/}"
                if [[ -e $candidate ]]; then print -r -- ${candidate:A}; return 0; fi
            done ;;
        @loader_path/*)
            candidate="${file:h}/${name#@loader_path/}"
            if [[ -e $candidate ]]; then print -r -- ${candidate:A}; return 0; fi ;;
        /*)
            if [[ -e $name ]]; then print -r -- ${name:A}; return 0; fi ;;
    esac
    echo "Cannot find $name, which $file needs." >&2
    return 1
}

# Copies the speech engine into the staged bundle: whisper-server in Contents/MacOS, every
# non-system library it links in Contents/Frameworks, and ggml's runtime backends next to
# whisper-server. All references are rewritten to @rpath, so the app runs without Homebrew.
bundle_engine() {
    if [[ ! -x $engine_source ]]; then
        echo "The speech engine (whisper-server) is not installed. Install it with: brew install whisper-cpp" >&2
        exit 1
    fi
    local macos="$stage/Contents/MacOS" frameworks="$stage/Contents/Frameworks"
    local file dest dep real id name rpath backends="" backend
    local -a pending args
    local -A bundled    # real source path -> its path in the bundle
    mkdir -p "$frameworks"
    file=${engine_source:A}
    bundled[$file]="$macos/whisper-server"
    pending=($file)
    while (( $#pending )); do
        file=$pending[1]; shift pending
        dest=$bundled[$file]
        cp "$file" "$dest"; chmod u+w "$dest"
        codesign --remove-signature "$dest"
        args=()
        id=$(otool -D "$file" | sed -n 2p)
        if [[ -n $id ]]; then args+=(-id "@rpath/${dest:t}"); fi
        for dep in ${(f)"$(otool -L "$file" | awk 'NR > 1 {print $1}')"}; do
            if [[ $dep == "$id" || $dep == /usr/lib/* || $dep == /System/* ]]; then continue; fi
            real=$(resolve_library "$file" "$dep")
            if [[ -z ${bundled[$real]-} ]]; then
                name=$(otool -D "$real" | sed -n 2p)
                bundled[$real]="$frameworks/${${name:-$dep}:t}"
                pending+=($real)
                # ggml loads its compute backends (Metal, BLAS, CPU variants) at runtime from the
                # libexec directory it was built with, the executable's directory and the working directory.
                if [[ ${real:t} == libggml.[0-9]*.dylib ]]; then
                    backends=${real:h:h}/libexec
                    for backend in $backends/libggml-*.so(N); do
                        bundled[${backend:A}]="$macos/${backend:t}"
                        pending+=(${backend:A})
                    done
                fi
            fi
            args+=(-change "$dep" "@rpath/${bundled[$real]:t}")
        done
        for rpath in ${(f)"$(otool -l "$file" | awk '$2 == "LC_RPATH" {getline; getline; print $2}')"}; do
            args+=(-delete_rpath "$rpath")
        done
        if [[ $dest == $frameworks/* ]]; then args+=(-add_rpath @loader_path); else args+=(-add_rpath @loader_path/../Frameworks); fi
        install_name_tool "${args[@]}" "$dest"
    done
    # The backend directory ggml was built with is searched first, so a Mac with the same Homebrew
    # ggml would load Homebrew's backends instead of the bundled ones. Blank that C string.
    if [[ -n $backends ]]; then
        for file in $bundled; do
            BACKENDS=$backends perl -0777 -pi -e 's/\Q$ENV{BACKENDS}\E(?=\0)/"\0" x length $ENV{BACKENDS}/ge' "$file"
        done
    fi
    for file in $bundled; do
        if grep -qaF /opt/homebrew "$file"; then
            echo "${file#$stage/} still refers to /opt/homebrew." >&2
            exit 1
        fi
    done
}

# Signs the bundled engine inside-out, before the app itself: libraries and backends, then whisper-server.
sign_engine() {
    local file
    for file in "$stage"/Contents/Frameworks/*.dylib(N) "$stage"/Contents/MacOS/*.so(N); do
        codesign --force --sign "$identity" --keychain "$keychain" "$file"
    done
    codesign --force --sign "$identity" --keychain "$keychain" --identifier dev.buddial.whisper-server "$stage/Contents/MacOS/whisper-server"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
clang -isysroot "$sdk_dir" -Wall -Wextra -Werror "$src/gesture_test.c" -o "$work/gesture-test"
"$work/gesture-test"
clang -isysroot "$sdk_dir" -fobjc-arc -Wall -Wextra -framework Foundation "$src/debug_clips_test.m" "$src/DebugClips.m" -o "$work/debug-test"
"$work/debug-test"

stage="$work/Buddial.app"
mkdir -p "$stage/Contents/MacOS"
cp "$src/Info.plist" "$stage/Contents/Info.plist"
# macOS 26 is the floor: Homebrew's whisper.cpp, bundled below, is built for it.
clang -isysroot "$sdk_dir" -mmacosx-version-min=26.0 -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    -framework AppKit -framework ApplicationServices -framework AVFoundation -framework CoreAudio -framework CoreMedia \
    -framework IOBluetooth -framework QuartzCore -framework ServiceManagement \
    "$src/main.m" "$src/BudSensor.m" "$src/Recorder.m" "$src/Transcriber.m" "$src/Feedback.m" "$src/Overlay.m" \
    "$src/SettingsWindow.m" "$src/BenchmarkPanel.m" "$src/MonitorPanel.m" "$src/DebugClips.m" "$src/ModelStore.m" "$src/OnboardingWindow.m" "$src/GestureStage.m" \
    -o "$stage/Contents/MacOS/Buddial"
bundle_engine

ensure_identity
sign_engine
codesign --force --sign "$identity" --keychain "$keychain" --identifier dev.buddial "$stage"
codesign --verify --strict --deep "$stage"
rm -rf "$app_dir"
mv "$stage" "$app_dir"
echo "Installed $app_dir"
codesign -dr - "$app_dir" 2>&1 | tail -n 1
