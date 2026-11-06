#!/bin/bash
# Builds Motion Controller for Release and wraps it in an installer package that drops it into /Applications.
#
# The package is as trustworthy as this Mac's keychain allows, and the script says which of the three it made:
#
#   1. Notarized   — Developer ID Application + Developer ID Installer certificates and a notarytool profile.
#                    Opens on any Mac with no warning. This is the only one fit for sending to other people.
#   2. Signed only — the two Developer ID certificates but no notarization. Gatekeeper still blocks it on
#                    another Mac; signing alone has not been enough since Catalina.
#   3. Untrusted   — no Developer ID certificate. Fine on this Mac, needs a right-click > Open elsewhere.
#
# Every step that can be checked is checked, and a failed check stops the build rather than shipping a package
# that only looks right. The gates are: the architectures the binary really contains, the absence of the
# debug-only get-task-allow entitlement (notarization rejects it outright), hardened runtime, a secure
# timestamp, the non-redistributable face model staying out of the payload, and the payload holding nothing
# but the app.
#
# Usage: Scripts/make-installer.sh [output-directory]   (default: dist/)
#
# Environment:
#   MC_NOTARY_PROFILE   notarytool keychain profile to notarize with. Create it once, interactively:
#                         xcrun notarytool store-credentials MotionController \
#                           --apple-id <id> --team-id RWGR7K8RB6 --password <app-specific-password>
#                       Unset means "skip notarization"; the script says so instead of failing.
#   MC_NOTARY_KEYCHAIN  Keychain holding that profile, when it isn't the default one. Over SSH the login keychain
#                       stays locked, so a build Mac keeps its profile in a keychain of its own (bitbytebot:
#                       developer-id.keychain-db with profile bitbytebot-notary), unlocked before the script runs.
#   MC_SIGN_IDENTITY    Override the app signing identity instead of letting the script pick one.

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
output="${1:-dist}"
work="$output/work"
app_name="MotionController.app"
build_log="$work/build.log"

# $work is deliberately left behind when something fails — the build log and the half-made package in it are
# the only way to tell why — and removed once the package is finished.
fail() {
    echo "✗ $1" >&2
    [ -s "$build_log" ] && { echo "  last lines of $build_log:" >&2; tail -25 "$build_log" >&2; }
    echo "  the working directory is kept at $work" >&2
    exit 1
}
trap 'fail "failed at line $LINENO"' ERR

echo "▸ Checking the tools"
for tool in xcodegen xcodebuild pkgbuild productbuild codesign pkgutil spctl ditto lipo python3 shasum; do
    command -v "$tool" >/dev/null || fail "$tool is not installed (xcodegen comes from \`brew install xcodegen\`)"
done

# The AdaFace weights are non-commercial, which is why the repo does not carry them and the app downloads them
# into Application Support at runtime instead. `sources: App` would sweep anything left in App/Vision/Models
# straight into the bundle, so a package built on a machine that has them would redistribute them.
if [ -n "$(find App/Vision/Models -mindepth 1 2>/dev/null | head -1)" ]; then
    fail "App/Vision/Models is not empty, and the installer must not redistribute the face model.
  Move it aside while packaging — the app downloads its own copy on first use:
    mv App/Vision/Models \"\$TMPDIR/MotionController-Models\""
fi

echo "▸ Looking for signing identities"
find_identity() {
    security find-identity -v -p "$2" 2>/dev/null | sed -n "s/.*\"\($1[^\"]*\)\".*/\1/p" | head -1
}
app_identity="${MC_SIGN_IDENTITY:-$(find_identity "Developer ID Application" codesigning)}"
installer_identity="$(find_identity "Developer ID Installer" basic)"
# Falling back to the development certificate keeps the local path working, and a stable identity is what keeps
# the Accessibility grant across rebuilds — ad-hoc signing resets it every time.
if [ -z "$app_identity" ]; then
    app_identity="$(find_identity "Apple Development" codesigning)"
    [ -n "$app_identity" ] || fail "no signing identity at all: neither Developer ID Application nor Apple Development"
fi
case "$app_identity" in
    "Developer ID Application"*) trusted=yes ;;
    *) trusted=no ;;
esac
echo "  app:       $app_identity"
echo "  installer: ${installer_identity:-(none)}"

echo "▸ Generating the project and building Release"
mkdir -p "$work"
xcodegen generate >"$build_log" 2>&1
# ARCHS has to be forced here, not in project.yml: an unqualified `xcodebuild build` picks this Mac as the
# destination, and the destination narrows ARCHS to the one architecture it runs, however the project is set up.
# Without this the package claims to support Intel and installs an app that cannot launch there.
# Xcode's own signing is switched off: everything is signed by hand below anyway, and Xcode insists on a
# development certificate that a release Mac holding only Developer ID ones doesn't have (bitbytebot, 2026-11-06:
# "No signing certificate \"Mac Development\" found").
xcodebuild -project MotionController.xcodeproj -scheme MotionController -configuration Release \
    -derivedDataPath build/DerivedData \
    ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" CODE_SIGNING_ALLOWED=NO \
    build >>"$build_log" 2>&1
built="build/DerivedData/Build/Products/Release/$app_name"
[ -d "$built" ] || fail "no Release build at $built"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$built/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$built/Contents/Info.plist")"
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$built/Contents/Info.plist")"
echo "▸ $identifier $version ($build_number)"

echo "▸ Staging the payload"
rm -rf "$work/root" "$work/scripts" "$work/resources"
mkdir -p "$work/root/Applications" "$work/scripts" "$work/resources"
# ditto, not cp: the code signature travels with the extended attributes.
ditto "$built" "$work/root/Applications/$app_name"
staged="$work/root/Applications/$app_name"

# Signing by hand rather than leaving it to xcodebuild, because the two flags that decide whether the package
# can ever be notarized are exactly the two xcodebuild chooses for itself: it passes --timestamp=none for a
# development certificate, and it injects get-task-allow into any build it thinks you might debug.
echo "▸ Signing the app"
timestamp_flag=--timestamp
sign_bundle() {
    # Nested code first: the outer seal covers the inner signatures, so signing the app first would invalidate it.
    local nested
    while IFS= read -r nested; do
        [ -n "$nested" ] || continue
        codesign --force --sign "$app_identity" --options runtime "$timestamp_flag" \
            --generate-entitlement-der "$nested" >>"$build_log" 2>&1 || return 1
    done < <(find "$staged/Contents" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' \))
    codesign --force --sign "$app_identity" --options runtime "$timestamp_flag" \
        --generate-entitlement-der --entitlements App/MotionController.entitlements "$staged" \
        >>"$build_log" 2>&1 || return 1
}
if ! sign_bundle; then
    # A secure timestamp needs Apple's timestamp server, so an offline machine cannot make a notarizable
    # package. Say that instead of silently producing one that notarization would reject later.
    [ "$trusted" = yes ] \
        && fail "signing with a secure timestamp failed, and notarization requires one — check the network"
    echo "  ! no secure timestamp (timestamp server unreachable); fine on this Mac, not notarizable"
    timestamp_flag=--timestamp=none
    sign_bundle || fail "could not sign the app even without a timestamp"
fi

echo "▸ Checking the signed app"
codesign --verify --deep --strict --verbose=2 "$staged" >>"$build_log" 2>&1 \
    || fail "the signed app does not verify"
archs="$(lipo -archs "$staged/Contents/MacOS/MotionController")"
case "$archs" in *arm64*) ;; *) fail "the binary has no arm64 slice (got: $archs)" ;; esac
entitlements="$(codesign -d --entitlements :- "$staged" 2>/dev/null)"
case "$entitlements" in
    *get-task-allow*) fail "get-task-allow survived into the signature; notarization would reject this build" ;;
esac
case "$entitlements" in
    *device.camera*) ;; *) fail "the camera entitlement is missing, and the app cannot see a frame without it" ;;
esac
signature="$(codesign -dvv "$staged" 2>&1)"
case "$signature" in *"flags=0x10000(runtime)"*) ;; *) fail "hardened runtime is not set on the signed app" ;; esac
echo "  architectures:     $archs"
echo "  hardened runtime:  yes"
case "$signature" in
    *Timestamp=*) echo "  secure timestamp:  yes" ;;
    *) echo "  secure timestamp:  no" ;;
esac

# A copy left running would keep the old binary, and its event tap with it.
cat > "$work/scripts/preinstall" <<'PREINSTALL'
#!/bin/bash
pkill -x MotionController || true
exit 0
PREINSTALL
chmod +x "$work/scripts/preinstall"

# Installer.app decodes a charset-less page as Mac Roman, which turns every Korean line into mojibake;
# the meta tag is what makes it read the UTF-8 these heredocs are written in.
cat > "$work/resources/welcome.html" <<'WELCOME'
<html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"></head>
<body style="font: -apple-system-body; padding: 8px">
<h2>Motion Controller</h2>
<p>웹캠으로 손 제스처를 읽어 데스크톱 전환, 재생/정지, 볼륨·밝기, 커서와 클릭을 조작하는 메뉴바 앱입니다.
<code>/Applications</code>에 설치됩니다.</p>
<p><b>설치 후 두 가지 권한이 필요합니다.</b></p>
<ul>
<li><b>카메라</b> — 처음 실행할 때 물어봅니다. 영상은 이 Mac 안에서만 처리하고 전송하지 않습니다.</li>
<li><b>손쉬운 사용</b> — 키보드·마우스 이벤트를 보내기 위해 필요합니다. 앱이 안내하는 버튼으로 열 수 있고,
켠 뒤에는 앱을 다시 실행해 주세요.</li>
</ul>
<p>얼굴 인식(까만 화면 잠금)에 쓰는 모델은 라이선스 때문에 앱에 넣을 수 없어, <b>앱 안의 버튼으로 한 번
내려받으면</b> 됩니다. 약 44MB, 6초쯤 걸립니다.</p>
</body></html>
WELCOME

cat > "$work/resources/conclusion.html" <<'CONCLUSION'
<html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"></head>
<body style="font: -apple-system-body; padding: 8px">
<h2>설치 완료</h2>
<p><code>/Applications/MotionController.app</code>을 실행하면 메뉴바에 손 아이콘이 생깁니다.
Dock 아이콘은 없습니다.</p>
<ol>
<li>처음 실행하면 <b>사용법 체험</b> 창이 열립니다. 미션을 세 번씩 해 보면 제스처가 손에 익습니다.</li>
<li>커서가 손과 맞지 않으면 메뉴 &gt; <b>커서 영역 보정</b>으로 네 모서리를 두 번 가리켜 주세요.</li>
<li>화면 전체 확대/축소를 쓰려면 시스템 설정 &gt; 손쉬운 사용 &gt; 확대/축소를 켜야 합니다.
튜토리얼에 그 설정을 여는 버튼이 있습니다.</li>
</ol>
</body></html>
CONCLUSION

echo "▸ Building the component package"
component="$work/MotionControllerComponent.pkg"
# Left to itself pkgbuild marks the app relocatable, and the installer then overwrites whichever copy
# LaunchServices already knows about instead of /Applications — on this Mac that was the build/DerivedData
# build, which a rebuild then wipes. BundleIsRelocatable false drops the <relocate> element from PackageInfo.
components="$work/component.plist"
pkgbuild --analyze --root "$work/root" "$components" >>"$build_log" 2>&1
python3 -I - "$components" <<'PYTHON'
import plistlib
import sys
path = sys.argv[1]
with open(path, "rb") as file:
    bundles = plistlib.load(file)
if not bundles:
    sys.exit("pkgbuild --analyze found no bundles to pin")
for bundle in bundles:
    bundle["BundleIsRelocatable"] = False
with open(path, "wb") as file:
    plistlib.dump(bundles, file)
PYTHON
pkgbuild --root "$work/root" --component-plist "$components" --scripts "$work/scripts" \
    --identifier "$identifier" --version "$version" --install-location / --ownership recommended \
    "$component" >>"$build_log" 2>&1

echo "▸ Checking the payload"
# Read back what actually went into the package rather than trusting the directory it was built from.
# The ._ entries are not files that get installed: pkgbuild serializes extended attributes (every file here
# carries com.apple.provenance) as AppleDouble members of the archive, and the installer consumes them.
payload="$(pkgutil --payload-files "$component" | grep -v '/\._[^/]*$')"
case "$payload" in
    *.mlpackage*|*.mlmodelc*) fail "the payload carries a Core ML model, which this package may not redistribute" ;;
esac
stray="$(printf '%s\n' "$payload" | sed -n 's|^\./\([^/]*\).*|\1|p' | sort -u | grep -v '^Applications$' || true)"
[ -z "$stray" ] || fail "the payload installs outside /Applications: $(printf '%s' "$stray" | tr '\n' ' ')"
printf '%s\n' "$payload" | grep -qx "./Applications/$app_name" \
    || fail "the payload does not contain /Applications/$app_name"
echo "  /Applications/$app_name only ($(printf '%s\n' "$payload" | grep -c .) entries)"

echo "▸ Building the installer"
# Synthesized rather than hand-written, then the welcome and conclusion pages are spliced in.
distribution="$work/distribution.xml"
productbuild --synthesize --package "$component" "$distribution" >>"$build_log" 2>&1
# hostArchitectures is taken from the binary, so the installer can never claim an architecture the app lacks.
# productbuild synthesizes its own <options> claiming x86_64,arm64 whatever the payload actually contains —
# that is how 0.1.3 shipped an arm64-only app that an Intel Mac would happily install and then fail to launch.
# So the synthesized element is removed rather than left to compete with this one.
host_architectures="$(printf '%s' "$archs" | tr ' ' ',')"
python3 -I - "$distribution" "$host_architectures" <<'PYTHON'
import re
import sys
path, host_architectures = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as file:
    text = file.read()
text, removed = re.subn(r"[ \t]*<options\b[^>]*/>\n?", "", text)
if removed == 0:
    sys.exit("no <options> element in the synthesized distribution; productbuild changed shape")
extra = (
    '\n    <title>Motion Controller</title>'
    '\n    <welcome file="welcome.html" mime-type="text/html"/>'
    '\n    <conclusion file="conclusion.html" mime-type="text/html"/>'
    '\n    <options customize="never" require-scripts="false" hostArchitectures="%s"/>' % host_architectures
)
# After the root element's own opening tag, not after the XML declaration.
root = re.search(r"<installer-gui-script[^>]*>", text)
if root is None:
    sys.exit("no installer-gui-script element in the synthesized distribution")
with open(path, "w", encoding="utf-8") as file:
    file.write(text[:root.end()] + extra + text[root.end():])
PYTHON
[ "$(grep -c '<options' "$distribution")" = 1 ] || fail "the distribution ended up with more than one <options> element"
grep -q "hostArchitectures=\"$host_architectures\"" "$distribution" \
    || fail "the distribution does not declare the architectures the binary has ($host_architectures)"
echo "  declares: $host_architectures"

package="$output/MotionController-$version.pkg"
rm -f "$package"
if [ -n "$installer_identity" ]; then
    echo "▸ Signing the installer with $installer_identity"
    productbuild --distribution "$distribution" --resources "$work/resources" --package-path "$work" \
        --sign "$installer_identity" --timestamp "$package" >>"$build_log" 2>&1
else
    productbuild --distribution "$distribution" --resources "$work/resources" --package-path "$work" \
        "$package" >>"$build_log" 2>&1
fi

notarized=no
# Both certificates matter here, not just the installer one: Apple notarizes what is inside the package too,
# so submitting an Apple-Development-signed app would buy a rejection this script can see coming.
if [ -n "${MC_NOTARY_PROFILE:-}" ] && [ "$trusted" = yes ] && [ -n "$installer_identity" ]; then
    echo "▸ Notarizing as $MC_NOTARY_PROFILE (this uploads the package to Apple and waits)"
    xcrun notarytool submit "$package" --keychain-profile "$MC_NOTARY_PROFILE" \
        ${MC_NOTARY_KEYCHAIN:+--keychain "$MC_NOTARY_KEYCHAIN"} --wait \
        || fail "notarization failed; \`xcrun notarytool log <submission-id> --keychain-profile $MC_NOTARY_PROFILE\` says why"
    # Stapling writes the ticket into the package so it validates even on a Mac that cannot reach Apple.
    xcrun stapler staple "$package" >>"$build_log" 2>&1 || fail "the package was notarized but could not be stapled"
    xcrun stapler validate "$package" >>"$build_log" 2>&1 || fail "the stapled ticket does not validate"
    notarized=yes
fi

echo "▸ Checking the finished package"
# Both of these report by exit code as well as on stdout — 1 from pkgutil and 3 from spctl just mean
# "not signed" and "rejected", which are findings to print, not errors to stop on.
signature_status="$(pkgutil --check-signature "$package" 2>&1 | sed -n 's/^ *Status: *//p' || true)"
gatekeeper="$(spctl -a -vvv -t install "$package" 2>&1 || true)"
echo "  signature:   ${signature_status:-unknown}"
case "$gatekeeper" in
    *accepted*) echo "  Gatekeeper:  accepted" ;;
    *) echo "  Gatekeeper:  rejected ($(printf '%s' "$gatekeeper" | sed -n 's/^source=//p' | head -1))" ;;
esac

trap - ERR
rm -rf "$work"
echo
echo "✓ $package"
echo "  $(du -h "$package" | cut -f1)  $(shasum -a 256 "$package" | cut -d' ' -f1)"
echo

# The closing note is derived from what the checks above actually found, so it cannot drift out of date.
if [ "$notarized" = yes ]; then
    cat <<'NOTARIZED'
  공증까지 끝난 패키지입니다. 어느 Mac에서나 경고 없이 열립니다.
NOTARIZED
elif [ "$trusted" = yes ] && [ -n "$installer_identity" ]; then
    cat <<NOTE
  Developer ID로 서명됐지만 공증(notarization)은 하지 않았습니다. Catalina 이후로는 서명만으로는
  부족해서, 다른 Mac에서는 여전히 Gatekeeper가 막습니다. 공증까지 하려면 한 번만 설정해 두면 됩니다.

    xcrun notarytool store-credentials MotionController \\
      --apple-id <Apple ID> --team-id RWGR7K8RB6 --password <앱 암호>

  그다음부터는 MC_NOTARY_PROFILE=MotionController $0 로 만들면 공증과 스테이플까지 합니다.
  앱 암호는 appleid.apple.com에서 발급합니다.
NOTE
else
    missing=""
    [ "$trusted" = yes ] || missing="Developer ID Application"
    [ -n "$installer_identity" ] || missing="${missing:+$missing, }Developer ID Installer"
    cat <<NOTE
  이 패키지는 다른 Mac에 보낼 수 없습니다 — 이 키체인에 없는 인증서: $missing.
  지금 서명에 쓴 인증서: $app_identity

  - 이 Mac에서는 그대로 열립니다.
  - 다른 Mac에서는 Gatekeeper가 막습니다. 받는 쪽에서 우클릭 > 열기, 또는
    xattr -dr com.apple.quarantine <파일>.pkg 를 한 번 해 주면 됩니다.

  제대로 배포하려면 유료 Apple Developer Program이 필요하고, 순서는 이렇습니다.
    1. Xcode > Settings > Accounts > Manage Certificates 에서 Developer ID Application과
       Developer ID Installer 인증서를 만듭니다 (팀 RWGR7K8RB6).
    2. xcrun notarytool store-credentials MotionController --apple-id <Apple ID> \\
         --team-id RWGR7K8RB6 --password <앱 암호>
    3. MC_NOTARY_PROFILE=MotionController $0
  인증서가 생기면 이 스크립트가 알아서 찾아 씁니다. 바꿀 설정은 없습니다.
NOTE
fi
