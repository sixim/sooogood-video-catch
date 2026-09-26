import Foundation

#if !MEDIAFETCH_STORE_PROFILE
/// Python side of the bridge. Reads one JSON request on stdin, talks to the
/// running Resolve through Blackmagic's official scripting module, and prints
/// exactly one JSON object on stdout. Compatible with Python 3.6+.
enum ResolveBridgeScript {
    static let source = #"""
import json
import sys


def reply(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False))
    sys.stdout.flush()
    sys.exit(0)


def fail(code, detail=""):
    reply({"ok": False, "error": code, "detail": str(detail)})


try:
    request = json.load(sys.stdin)
except Exception as exc:
    fail("bad_request", exc)

try:
    import DaVinciResolveScript as dvr
except Exception as exc:
    fail("module", exc)

resolve = dvr.scriptapp("Resolve")
if resolve is None:
    fail("not_connected")

product = resolve.GetProductName() or "DaVinci Resolve"
version = resolve.GetVersionString() or ""
project = resolve.GetProjectManager().GetCurrentProject()

if request.get("op") == "status":
    reply({"ok": True, "status": {
        "product": product, "version": version,
        "project": project.GetName() if project else None}})

if project is None:
    fail("no_project")

pool = project.GetMediaPool()
folder = pool.GetRootFolder()
for name in request.get("binPath", []):
    child = None
    for sub in folder.GetSubFolderList() or []:
        if sub.GetName() == name:
            child = sub
            break
    if child is None:
        child = pool.AddSubFolder(folder, name)
    if child is None:
        fail("bin_failed", name)
    folder = child
pool.SetCurrentFolder(folder)

existing = {}
for clip in folder.GetClipList() or []:
    path = clip.GetClipProperty("File Path")
    if path:
        existing[path] = clip

clips, failed, subtitles, pool_items = [], [], [], []
for spec in request.get("clips", []):
    path = spec["path"]
    item = existing.get(path)
    reused = item is not None
    if item is None:
        imported = pool.ImportMedia([path]) or []
        item = imported[0] if imported else None
    if item is None:
        failed.append(path)
        continue
    metadata_failures = []
    for key, value in (spec.get("metadata") or {}).items():
        if not item.SetMetadata(key, value):
            metadata_failures.append(key)
    for key, value in (spec.get("thirdParty") or {}).items():
        if not item.SetThirdPartyMetadata(key, value):
            metadata_failures.append(key)
    proxy_linked = None
    if spec.get("proxy"):
        proxy_linked = bool(item.LinkProxyMedia(spec["proxy"]))
    pool_items.append(item)
    clips.append({"path": path, "name": item.GetName(), "reused": reused,
                  "metadataFailures": metadata_failures, "proxyLinked": proxy_linked})

for path in request.get("subtitles", []):
    if path in existing:
        subtitles.append(path)
        continue
    if pool.ImportMedia([path]):
        subtitles.append(path)
    else:
        failed.append(path)

timeline = None
if request.get("timelineName") and pool_items:
    created = pool.CreateTimelineFromClips(request["timelineName"], pool_items)
    timeline = created.GetName() if created else None

reply({"ok": True, "result": {
    "product": product, "version": version, "project": project.GetName(),
    "bin": request.get("binPath", []), "clips": clips, "subtitles": subtitles,
    "failed": failed, "timeline": timeline}})
"""#
}
#endif
