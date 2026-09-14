#!/bin/bash
# Builds Motion Controller for Release and wraps it in an installer package that drops it into /Applications.
#
# The app is signed with the Apple Development certificate this repo is set up for, and there is no Developer ID
# (let alone notarization), so this package is for this Mac and for anyone willing to click past Gatekeeper — see
# the note the script prints at the end. Sign the package too if a "Developer ID Installer" identity ever exists:
# the script picks it up on its own.
#
# Usage: Scripts/make-installer.sh [output-directory]   (default: dist/)

set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
output="${1:-dist}"
work="$output/work"
app_name="MotionController.app"

echo "▸ Generating the project and building Release"
xcodegen generate >/dev/null
xcodebuild -project MotionController.xcodeproj -scheme MotionController -configuration Release \
    -derivedDataPath build/DerivedData build >/dev/null
built="build/DerivedData/Build/Products/Release/$app_name"
[ -d "$built" ] || { echo "✗ No Release build at $built"; exit 1; }

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$built/Contents/Info.plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$built/Contents/Info.plist")"
identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$built/Contents/Info.plist")"
echo "▸ $identifier $version ($build_number)"

echo "▸ Staging the payload"
rm -rf "$work"
mkdir -p "$work/root/Applications" "$work/scripts" "$work/resources"
# ditto, not cp: the code signature travels with the extended attributes.
ditto "$built" "$work/root/Applications/$app_name"
codesign --verify --deep --strict "$work/root/Applications/$app_name"

# A copy left running would keep the old binary, and its event tap with it.
cat > "$work/scripts/preinstall" <<'PREINSTALL'
#!/bin/bash
pkill -x MotionController || true
exit 0
PREINSTALL
chmod +x "$work/scripts/preinstall"

cat > "$work/resources/welcome.html" <<'WELCOME'
<html><body style="font: -apple-system-body; padding: 8px">
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
<html><body style="font: -apple-system-body; padding: 8px">
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
pkgbuild --root "$work/root" --scripts "$work/scripts" --identifier "$identifier" \
    --version "$version" --install-location / --ownership recommended "$component" >/dev/null

echo "▸ Building the installer"
# Synthesized rather than hand-written, then the welcome and conclusion pages are spliced in.
distribution="$work/distribution.xml"
productbuild --synthesize --package "$component" "$distribution" >/dev/null
python3 - "$distribution" <<'PYTHON'
import re
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as file:
    text = file.read()
extra = (
    '\n    <title>Motion Controller</title>'
    '\n    <welcome file="welcome.html" mime-type="text/html"/>'
    '\n    <conclusion file="conclusion.html" mime-type="text/html"/>'
    '\n    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>'
)
# After the root element's own opening tag, not after the XML declaration.
root = re.search(r"<installer-gui-script[^>]*>", text)
if root is None:
    sys.exit("no installer-gui-script element in the synthesized distribution")
with open(path, "w", encoding="utf-8") as file:
    file.write(text[:root.end()] + extra + text[root.end():])
PYTHON

installer_identity="$(security find-identity -v -p basic 2>/dev/null | sed -n 's/.*"\(Developer ID Installer[^"]*\)".*/\1/p' | head -1)"
package="$output/MotionController-$version.pkg"
if [ -n "$installer_identity" ]; then
    echo "▸ Signing with $installer_identity"
    productbuild --distribution "$distribution" --resources "$work/resources" --package-path "$work" \
        --sign "$installer_identity" "$package" >/dev/null
else
    productbuild --distribution "$distribution" --resources "$work/resources" --package-path "$work" \
        "$package" >/dev/null
fi

rm -rf "$work"
echo
echo "✓ $package"
ls -lh "$package" | awk '{print "  " $5}'
if [ -z "$installer_identity" ]; then
    cat <<'UNSIGNED'

  이 패키지는 서명되지 않았습니다 (이 Mac에는 "Developer ID Installer" 인증서가 없습니다).
  - 이 Mac에서는 그냥 열립니다.
  - 다른 Mac에서는 Gatekeeper가 막습니다. 받는 쪽에서 우클릭 > 열기, 또는
    xattr -dr com.apple.quarantine <파일>.pkg 를 한 번 해 주면 됩니다.
  - 배포용으로 제대로 만들려면 유료 Apple Developer Program의 Developer ID 인증서와 공증(notarization)이
    필요하고, 그 인증서가 생기면 이 스크립트가 알아서 서명합니다.
UNSIGNED
fi
