import ObjC from 'frida-objc-bridge';

function ts() {
  var d = new Date();
  return d.toISOString().substr(11, 12);
}
function log(msg) {
  send({ m: ts() + ' ' + msg });
}
function desc(v) {
  try {
    if (v === null || v === undefined) return 'nil';
    var o = (v instanceof ObjC.Object) ? v : new ObjC.Object(v);
    if (o.isNull()) return 'nil';
    var s = o.toString();
    return s.length > 2000 ? s.substr(0, 2000) + '...' : s;
  } catch (e) { return '<' + e + '>'; }
}
function utf8(idPtr) {
  try {
    var o = new ObjC.Object(idPtr);
    if (o.isNull()) return null;
    return o.toString();
  } catch (e) { return null; }
}

function attachMethod(cls, sel, argCount, fmt) {
  var k = ObjC.classes[cls];
  if (!k) { log('class missing ' + cls); return false; }
  var m = k[sel];
  if (!m) { log('method missing ' + cls + ' ' + sel); return false; }
  try {
    Interceptor.attach(m.implementation, {
      onEnter: function (args) {
        try {
          var vals = [];
          for (var i = 0; i < argCount; i++) vals.push(desc(args[2 + i]));
          log('PLAYER ' + cls + ' ' + sel + ' ' + fmt + vals.join(' | '));
        } catch (e) { log('argerr ' + cls + ' ' + sel + ' ' + e); }
      }
    });
    log('hooked ' + cls + ' ' + sel);
    return true;
  } catch (e) { log('hookfail ' + cls + ' ' + sel + ' ' + e); return false; }
}

function dumpClassMethods(cls) {
  try {
    var k = ObjC.classes[cls];
    if (!k) { log('class missing ' + cls); return; }
    var names = (k.$ownMethods || []).filter(function (m) {
      var l = m.toLowerCase();
      return l.indexOf('url') >= 0 || l.indexOf('play') >= 0 || l.indexOf('video') >= 0 ||
             l.indexOf('source') >= 0 || l.indexOf('data') >= 0 || l.indexOf('load') >= 0;
    });
    log('CLASS ' + cls + ' : ' + names.join(' | '));
  } catch (e) { log('dumpfail ' + cls + ' ' + e); }
}

['FMVideoPlayerViewAV', 'FMVideoPlayerViewTB', 'FMVideoPlayerService',
 'FishVideoPlayerView', 'AXPPlayer', 'AliPlayer', 'AliyunPlayer',
 'AXPPlayerService', 'AXPCorePlayerView'].forEach(dumpClassMethods);

['FMVideoPlayerViewAV', 'FMVideoPlayerViewTB'].forEach(function (c) {
  attachMethod(c, '- loadWithVideoUrl:', 1, 'url=');
  attachMethod(c, '- loadWithVideoId:from:priority:', 3, 'id/from/pri=');
});
attachMethod('FishVideoPlayerView', '- setUrl:', 1, 'url=');
attachMethod('FMVideoPlayerService', '- setPlayUrl:', 1, 'url=');
attachMethod('AXPPlayer', '- setDataSource:dsCount:headers:', 3, 'ds/count/headers=');
attachMethod('FMVideoPlayerService', '- playWithUrl:', 1, 'url=');
attachMethod('FMVideoPlayerService', '- playVideo:', 1, 'video=');
attachMethod('FMVideoPlayerService', '- playWithVideoId:', 1, 'id=');
attachMethod('FMVideoPlayerService', '- loadVideoWithId:', 1, 'id=');

// ---------- NSURLSession request logging ----------
try {
  var dsm = ObjC.classes.NSURLSession['- dataTaskWithRequest:completionHandler:'];
  if (dsm) {
    Interceptor.attach(dsm.implementation, {
      onEnter: function (args) {
        try {
          var req = new ObjC.Object(args[2]);
          var url = req.URL().absoluteString().toString();
          var low = url.toLowerCase();
          if (low.indexOf('video') >= 0 || low.indexOf('m3u8') >= 0 || low.indexOf('mp4') >= 0 ||
              low.indexOf('media') >= 0 || low.indexOf('player') >= 0) {
            var body = '';
            try {
              var b = req.HTTPBody();
              if (b && !b.isNull() && b.length() > 0 && b.length() < 20000) body = b.bytes().readUtf8String(b.length());
            } catch (e) {}
            log('REQ ' + url + ' body=' + body);
          }
        } catch (e) { log('reqerr ' + e); }
      }
    });
    log('hooked NSURLSession dataTaskWithRequest');
  } else log('no dataTask hook');
} catch (e) { log('net hook fail ' + e); }

// ---------- AVFoundation ----------
try {
  var a = ObjC.classes.AVURLAsset['+ URLAssetWithURL:options:'];
  if (a) {
    Interceptor.attach(a.implementation, {
      onEnter: function (args) {
        try { log('AVURLAsset ' + new ObjC.Object(args[2]).absoluteString().toString()); } catch (e) {}
      }
    });
    log('hooked AVURLAsset');
  }
} catch (e) { log('avasset fail ' + e); }
try {
  var p = ObjC.classes.AVPlayerItem['+ playerItemWithURL:'];
  if (p) {
    Interceptor.attach(p.implementation, {
      onEnter: function (args) {
        try { log('AVPlayerItem ' + new ObjC.Object(args[2]).absoluteString().toString()); } catch (e) {}
      }
    });
    log('hooked AVPlayerItem');
  }
} catch (e) { log('avitem fail ' + e); }

log('script ready');
