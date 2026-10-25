#!/usr/bin/env python3
"""Attach to Amap on the test device and report UI state / take a screenshot.

Usage:
  frida_ui.py [--shot NAME] [--hierarchy]

Screenshot is written inside the app container's tmp directory; the path is
printed so it can be pulled with scp.
"""
import argparse
import json
import os
import sys

import frida


JS = r"""
(function () {
  var out = {};

  function cls(o) {
    if (!o) return null;
    try { return ObjC.Object(o).$className; } catch (e) { return null; }
  }

  var app = ObjC.classes.UIApplication.sharedApplication();
  var key = app.keyWindow() || app.windows().objectAtIndex(0);
  out.keyWindowClass = cls(key);
  var rvc = key.rootViewController();
  var chain = [];
  var vc = rvc;
  for (var i = 0; i < 12 && vc; i++) {
    var d = vc.description().toString();
    chain.push(String(vc.$className) + " :: " + d.substring(0, 160));
    vc = vc.presentedViewController();
  }
  out.vcChain = chain;

  function walk(v, depth, acc) {
    if (!v || depth > 8 || acc.length > 400) return;
    var node = {c: String(v.$className), hidden: v.hidden(), alpha: v.alpha()};
    try { node.frame = v.frame().toString(); } catch (e) {}
    acc.push(node);
    var subs = v.subviews();
    var n = subs.count();
    for (var i = 0; i < n; i++) walk(subs.objectAtIndex_(i), depth + 1, acc);
  }
  out.hierarchy = [];
  walk(key, 0, out.hierarchy);

  var splash = [];
  try {
    var all = ObjC.chooseSync(ObjC.classes.WINSplashView);
    for (var i = 0; i < all.length; i++) {
      splash.push({cls: String(all[i].$className), hidden: all[i].hidden(), frame: all[i].frame().toString()});
    }
  } catch (e) { splash.push({error: String(e)}); }
  out.splashViews = splash;

  var svc = null;
  try { svc = ObjC.classes.WINSplashScreenVAppService.sharedInstance(); } catch (e) {}
  if (svc && !svc.isNull()) {
    out.service = {status: String(svc.status ? svc.status() : "n/a")};
    try { out.service.show = svc.isShowing(); } catch (e) {}
  }

  var shot = null;
  if (%SHOT%) {
    try {
      var UIGetScreenImage = new NativeFunction(Module.findGlobalExportByName("UIGetScreenImage"), "pointer", []);
      var cg = UIGetScreenImage();
      var img = ObjC.classes.UIImage.imageWithCGImage_(cg);
      var UIImagePNGRepresentation = new NativeFunction(Module.findGlobalExportByName("UIImagePNGRepresentation"), "pointer", ["pointer"]);
      var png = UIImagePNGRepresentation(img);
      var path = %PATH%;
      png.writeToFile_atomically_(path, true);
      shot = path;
    } catch (e) { shot = "ERR " + e; }
  }
  out.screenshot = shot;
  send(out);
})();
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shot")
    ap.add_argument("--hierarchy", action="store_true")
    ap.add_argument("--host", default=os.environ.get("DEVICE_HOST", "127.0.0.1:27042"))
    ap.add_argument("--process", default="AMapiPhone")
    args = ap.parse_args()

    dev = frida.get_device_manager().add_remote_device(args.host)
    pid = None
    for p in dev.enumerate_processes():
        if p.name == args.process:
            pid = p.pid
    if pid is None:
        print("process not running")
        return 1
    session = dev.attach(pid)
    path = "/tmp/amap-shot-%s.png" % (args.shot or "now")
    js = JS.replace("%SHOT%", "true" if args.shot else "false")
    js = js.replace("%PATH%", json.dumps(path))
    script = session.create_script(js)
    result = []
    script.on("message", lambda m, d: result.append(m))
    script.load()
    import time
    for _ in range(50):
        if result:
            break
        time.sleep(0.1)
    if not result:
        print("no result")
        return 1
    msg = result[0]
    if msg["type"] != "send":
        print(json.dumps(msg, indent=2, ensure_ascii=False)[:2000])
        return 1
    out = msg["payload"]
    print(json.dumps({k: v for k, v in out.items() if k != "hierarchy"},
                     indent=2, ensure_ascii=False))
    if args.hierarchy:
        for n in out["hierarchy"]:
            print("   ", n)
    else:
        print("hierarchy nodes:", len(out["hierarchy"]))
    session.detach()
    return 0


if __name__ == "__main__":
    sys.exit(main())
